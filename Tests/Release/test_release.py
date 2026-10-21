"""Release packaging checks run offline; GitHub writes are exercised with a boundary fake."""
from pathlib import Path
import hashlib
import importlib.util
import io
import json
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
import zipfile

ROOT = Path(__file__).resolve().parents[2]
VERSION = '0.1.11'
COMMIT = 'a' * 40


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='ysg release ')
        self.addCleanup(self.temporary.cleanup)
        self.assets = Path(self.temporary.name)
        self.make_assets()

    def make_assets(self, commit=COMMIT):
        for arch in ['arm64', 'x86_64']:
            stem = 'YeShunguangPet-0.1.11-macOS-' + arch
            (self.assets / (stem + '.dmg')).write_bytes(b'controlled disk image')
            with zipfile.ZipFile(self.assets / (stem + '.zip'), 'w') as archive:
                base = stem + '/YeShunguangPet.app/Contents/'
                archive.writestr(base + 'Resources/build-info.json', json.dumps(
                    {'commit': commit, 'trackedChanges': False, 'architecture': arch}))
                archive.writestr(base + 'Info.plist', plistlib.dumps(
                    {'CFBundleShortVersionString': VERSION, 'CFBundleVersion': '12'}))
            for suffix in ['dmg', 'zip']:
                self.checksum(self.assets / (stem + '.' + suffix))

    def checksum(self, path):
        Path(str(path) + '.sha256').write_text(hashlib.sha256(path.read_bytes()).hexdigest() + '  ' + path.name + '\n')

    def check(self):
        return subprocess.run([sys.executable, str(ROOT / 'scripts/prepare-release.py'),
                               '--assets', str(self.assets), '--version', VERSION,
                               '--commit', COMMIT, '--check-only'], capture_output=True, text=True)

    def test_check_only_validates_both_architectures_without_credentials(self):
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report['commit'], COMMIT)
        self.assertEqual(len(report['assets']), 8)

    def module(self):
        spec = importlib.util.spec_from_file_location('prepare_release', ROOT / 'scripts/prepare-release.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_rejects_missing_extra_corrupt_or_symlinked_asset(self):
        selected = self.assets / 'YeShunguangPet-0.1.11-macOS-arm64.dmg'
        original = selected.read_bytes()
        for mode in ['missing', 'extra', 'corrupt', 'symlink']:
            with self.subTest(mode=mode):
                if mode == 'missing': selected.unlink()
                if mode == 'extra': (self.assets / 'unrelated.txt').write_text('extra')
                if mode == 'corrupt': selected.write_bytes(b'tampered')
                if mode == 'symlink':
                    target = self.assets.parent / (self.assets.name + '-outside')
                    target.write_bytes(original)
                    self.addCleanup(target.unlink)
                    selected.unlink(); selected.symlink_to(target)
                self.assertNotEqual(self.check().returncode, 0)
                if selected.is_symlink(): selected.unlink()
                selected.write_bytes(original)
                (self.assets / 'unrelated.txt').unlink(missing_ok=True)

    def test_rejects_wrong_source_even_when_all_checksums_match(self):
        self.make_assets(commit='b' * 40)
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('source', result.stderr.lower())

    def test_rejects_dirty_or_mislabeled_or_duplicate_zip_metadata(self):
        module = self.module()
        for mode in ['dirty', 'numeric-clean', 'architecture', 'version', 'duplicate']:
            with self.subTest(mode=mode):
                self.make_assets()
                archive = self.assets / 'YeShunguangPet-0.1.11-macOS-arm64.zip'
                base = 'YeShunguangPet-0.1.11-macOS-arm64/YeShunguangPet.app/Contents/'
                info = {'commit': COMMIT, 'trackedChanges': mode == 'dirty',
                        'architecture': 'x86_64' if mode == 'architecture' else 'arm64'}
                if mode == 'numeric-clean': info['trackedChanges'] = 0
                with zipfile.ZipFile(archive, 'w') as stream:
                    stream.writestr(base + 'Resources/build-info.json', json.dumps(info))
                    stream.writestr(base + 'Info.plist', plistlib.dumps(
                        {'CFBundleShortVersionString': '0.1.9' if mode == 'version' else VERSION}))
                    if mode == 'duplicate':
                        # Duplicate metadata has ambiguous meaning to ZIP consumers.
                        import warnings
                        with warnings.catch_warnings():
                            warnings.simplefilter('ignore', UserWarning)
                            stream.writestr(base + 'Resources/build-info.json', json.dumps(info))
                self.checksum(archive)
                with self.assertRaises(ValueError): module.collect_assets(self.assets, VERSION, COMMIT)

    def test_creates_only_draft_and_uploads_exact_eight_matching_assets(self):
        module = self.module(); api = ReleaseAPI(module)
        result = module.prepare_release(api, self.assets, VERSION, COMMIT, '拖拽导入及发版草稿')
        self.assertTrue(result['draft'])
        self.assertEqual(api.release['tag_name'], 'v0.1.11')
        self.assertEqual(api.release['target_commitish'], COMMIT)
        self.assertEqual(len(api.assets), 8)
        self.assertTrue(all(a['state'] == 'uploaded' and a['digest'].startswith('sha256:') for a in api.assets))
        self.assertFalse(any(method in ['PATCH', 'DELETE'] or path.startswith('git/refs') for method, path in api.requests))

    def test_invalid_packages_never_reach_github(self):
        module = self.module(); api = ReleaseAPI(module)
        (self.assets / 'YeShunguangPet-0.1.11-macOS-arm64.dmg').write_bytes(b'bad')
        with self.assertRaises(ValueError): module.prepare_release(api, self.assets, VERSION, COMMIT, 'notes')
        self.assertEqual(api.requests, [])

    def test_published_release_or_conflicting_tag_is_preserved(self):
        module = self.module()
        for mode in ['published', 'tag']:
            with self.subTest(mode=mode):
                api = ReleaseAPI(module)
                if mode == 'tag': api.tag = {'object': {'type': 'commit', 'sha': 'b' * 40}}
                else: api.release = {'id': 7, 'tag_name': 'v0.1.11', 'draft': False}
                with self.assertRaises(ValueError): module.prepare_release(api, self.assets, VERSION, COMMIT, 'notes')
                self.assertFalse(any(method != 'GET' for method, _ in api.requests))

    def test_annotated_tag_matching_commit_is_accepted(self):
        module = self.module(); api = ReleaseAPI(module)
        api.tag = {'object': {'type': 'tag', 'sha': 'c' * 40}}
        result = module.prepare_release(api, self.assets, VERSION, COMMIT, 'notes')
        self.assertTrue(result['draft'])

    def test_retry_resumes_partial_draft_and_completed_retry_does_not_write(self):
        module = self.module(); api = ReleaseAPI(module); api.fail_upload = 3
        with self.assertRaises(module.APIError): module.prepare_release(api, self.assets, VERSION, COMMIT, 'notes')
        self.assertTrue(api.release['draft']); self.assertEqual(len(api.assets), 2)
        api.fail_upload = None
        module.prepare_release(api, self.assets, VERSION, COMMIT, 'notes')
        self.assertEqual(len(api.assets), 8)
        api.requests.clear()
        module.prepare_release(api, self.assets, VERSION, COMMIT, 'notes')
        self.assertFalse(any(method != 'GET' for method, _ in api.requests))

    def test_conflicting_draft_asset_is_not_overwritten(self):
        module = self.module(); api = ReleaseAPI(module)
        module.prepare_release(api, self.assets, VERSION, COMMIT, 'notes')
        api.assets[0]['digest'] = 'sha256:' + '0' * 64
        api.requests.clear()
        with self.assertRaises(ValueError): module.prepare_release(api, self.assets, VERSION, COMMIT, 'notes')
        self.assertFalse(any(method != 'GET' for method, _ in api.requests))

    def test_conflicting_source_or_unexpected_asset_is_not_modified(self):
        module = self.module()
        for mode in ['source', 'extra', 'empty-notes']:
            with self.subTest(mode=mode):
                api = ReleaseAPI(module)
                module.prepare_release(api, self.assets, VERSION, COMMIT, 'notes')
                if mode == 'source': api.release['target_commitish'] = 'b' * 40
                if mode == 'extra': api.assets.append({'id': 100, 'name': 'unexpected'})
                api.requests.clear()
                with self.assertRaises(ValueError):
                    module.prepare_release(api, self.assets, VERSION, COMMIT, '' if mode == 'empty-notes' else 'notes')
                self.assertFalse(any(method != 'GET' for method, _ in api.requests))

    def test_transport_uses_upload_host_and_exact_binary_payload(self):
        module = self.module(); api = module.GitHub('Resker666/YeShunguangPet-macOS', 'offline-token')
        asset = self.assets / 'YeShunguangPet-0.1.11-macOS-arm64.dmg'
        requests = []
        def respond(request, timeout):
            requests.append(request)
            return io.BytesIO(b'{"id":1}')
        with patch.object(module, 'urlopen', respond):
            api.request('POST', 'releases/7/assets?name=' + asset.name, asset=asset)
            api.request('POST', 'releases', payload={'draft': True, 'target_commitish': COMMIT})
        self.assertEqual(requests[0].full_url, 'https://uploads.github.com/repos/Resker666/YeShunguangPet-macOS/releases/7/assets?name=' + asset.name)
        self.assertEqual(requests[0].data, asset.read_bytes())
        self.assertEqual(requests[0].get_header('Authorization'), 'Bearer offline-token')
        self.assertEqual(requests[1].full_url, 'https://api.github.com/repos/Resker666/YeShunguangPet-macOS/releases')
        self.assertEqual(json.loads(requests[1].data), {'draft': True, 'target_commitish': COMMIT})

    def test_transport_failure_does_not_expose_credentials(self):
        module = self.module(); api = module.GitHub('Resker666/YeShunguangPet-macOS', 'offline-private-token')
        with patch.object(module, 'urlopen', side_effect=HTTPError('https://api.github.com', 403, 'denied', {}, None)):
            with self.assertRaises(module.APIError) as caught: api.request('POST', 'releases', payload={'draft': True})
        self.assertEqual(caught.exception.status, 403)
        self.assertNotIn('offline-private-token', str(caught.exception))


class ReleaseAPI:
    """A GitHub boundary double; archive reading/checksums/release decisions remain real."""
    def __init__(self, module):
        self.module = module; self.release = None; self.assets = []; self.tag = None
        self.requests = []; self.fail_upload = None

    def request(self, method, path, payload=None, asset=None):
        self.requests.append((method, path))
        route = path.split('?')[0]
        if route.startswith('git/ref/'):
            if self.tag is None: raise self.module.APIError(404)
            return self.tag
        if route.startswith('git/tags/'):
            return {'object': {'type': 'commit', 'sha': COMMIT}}
        if method == 'GET' and route == 'releases': return [self.release] if self.release else []
        if method == 'POST' and route == 'releases':
            self.release = dict(payload, id=7, html_url='https://github.com/owner/repo/releases/tag/v0.1.11')
            return self.release.copy()
        if method == 'GET' and route == 'releases/7': return self.release.copy()
        if method == 'GET' and route == 'releases/7/assets': return [a.copy() for a in self.assets]
        if method == 'POST' and route == 'releases/7/assets':
            if len(self.assets) + 1 == self.fail_upload: raise self.module.APIError(503)
            result = {'id': len(self.assets) + 1, 'name': asset.name, 'state': 'uploaded',
                      'size': asset.stat().st_size, 'digest': 'sha256:' + hashlib.sha256(asset.read_bytes()).hexdigest()}
            self.assets.append(result); return result.copy()
        raise AssertionError('Unexpected GitHub operation: ' + method + ' ' + path)


if __name__ == '__main__':
    unittest.main()
