import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
import warnings
import zipfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
import voice_distribution as vd
from voice_fixtures import APP_COMMIT, COMMIT, ENGINE, FILES, VOICE, bundle, engine_folder, inputs, sha


class VoiceAssetTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def test_bundle_requires_exact_six_files_and_full_provenance(self):
        result = bundle(vd, self.root)
        self.assertEqual({p.name for p in (self.root / 'assets').iterdir()}, FILES)
        checked = vd.read_bundle(self.root / 'assets', version='1.0.0', tools_commit=COMMIT)
        self.assertEqual(checked.tools_commit, COMMIT)
        self.assertEqual({a.name for a in checked.assets}, FILES)
        self.assertEqual(checked.manifest['app']['sourceCommit'], APP_COMMIT)
        self.assertEqual(checked.manifest['engine']['architecture'], 'arm64')
        self.assertEqual(checked.manifest['voice']['id'], 'hutao-pilot-e1')
        (self.root / 'assets/unexpected.pth').write_bytes(b'extra')
        with self.assertRaises(ValueError): vd.read_bundle(self.root / 'assets', version='1.0.0', tools_commit=COMMIT)

    def test_asset_size_is_strictly_below_two_gib(self):
        self.assertTrue(vd.valid_asset_size(2**31 - 1))
        for size in [0, -1, 2**31, True]: self.assertFalse(vd.valid_asset_size(size))
        bundle(vd, self.root)
        with (self.root / 'assets' / ENGINE).open('wb') as f: f.truncate(2**31)
        with self.assertRaisesRegex(ValueError, 'size|大小'):
            vd.read_bundle(self.root / 'assets', version='1.0.0', tools_commit=COMMIT)

    def test_voice_zip_preserves_exact_three_file_package(self):
        folder, image, readme, notices = inputs(self.root)
        path = vd.build_voice_zip(folder, self.root / 'voice.zip', notices=notices)
        with zipfile.ZipFile(path) as z:
            self.assertEqual(set(z.namelist()), {'胡桃-试用-e1/voice.json', '胡桃-试用-e1/s2.pth',
                                              '胡桃-试用-e1/reference.wav', '来源与许可.md'})
            for name in ['voice.json', 's2.pth', 'reference.wav']:
                self.assertEqual(z.read('胡桃-试用-e1/' + name), (folder / name).read_bytes())
        with self.assertRaises(ValueError): vd.build_voice_zip(folder, path, notices=notices)

    def test_rejects_changed_source_or_manifest_without_modifying_original(self):
        engine = engine_folder(self.root)
        original = (engine / 'engine.json').read_bytes()
        digest = sha(original)
        result = vd.verify_engine_tree(engine, expected_manifest_sha256=digest)
        self.assertEqual(result['files'], 2)
        self.assertEqual((engine / 'engine.json').read_bytes(), original)
        (engine / 'payload/empty.txt').write_bytes(b'changed')
        with self.assertRaises(ValueError): vd.verify_engine_tree(engine, expected_manifest_sha256=digest)
        self.assertEqual((engine / 'engine.json').read_bytes(), original)

    def test_engine_rejects_extra_files_links_and_changed_executable_permission(self):
        engine = engine_folder(self.root); digest = sha((engine / 'engine.json').read_bytes())
        python = engine / 'payload/runtime/bin/python3.12'
        python.chmod(0o644)
        with self.assertRaises(ValueError): vd.verify_engine_tree(engine, expected_manifest_sha256=digest)
        python.chmod(0o755)
        extra = engine / 'payload/extra'; extra.write_bytes(b'x')
        with self.assertRaises(ValueError): vd.verify_engine_tree(engine, expected_manifest_sha256=digest)
        extra.unlink(); empty = engine / 'payload/empty.txt'; empty.unlink(); empty.symlink_to(python)
        with self.assertRaises(ValueError): vd.verify_engine_tree(engine, expected_manifest_sha256=digest)

    def test_rejects_unsafe_zip_entries_and_inner_notice(self):
        folder, image, readme, notices = inputs(self.root)
        original = vd.build_voice_zip(folder, self.root / 'valid.zip', notices=notices)
        with zipfile.ZipFile(original) as z: rows = [(i, z.read(i)) for i in z.infolist()]
        extras = ['../escape', '/absolute', '胡桃-试用-e1/安装说明.md', '胡桃-试用-e1/s2.pth']
        for index, extra in enumerate(extras):
            bad = self.root / ('bad' + str(index) + '.zip')
            with warnings.catch_warnings(), zipfile.ZipFile(bad, 'w') as z:
                warnings.simplefilter('ignore', UserWarning)
                for i, data in rows: z.writestr(i, data)
                z.writestr(extra, b'bad')
            with self.subTest(extra=extra), self.assertRaises(ValueError):
                vd.build_bundle(image, bad, self.root / ('out' + str(index)), tools_commit=COMMIT,
                                app_commit=APP_COMMIT, readme=readme, provenance={})

    def test_zip_rejects_link_and_wrong_pcm_reference(self):
        folder, image, readme, notices = inputs(self.root)
        archive = vd.build_voice_zip(folder, self.root / 'valid.zip', notices=notices)
        with zipfile.ZipFile(archive) as z: rows = [(i, z.read(i)) for i in z.infolist()]
        bad = self.root / 'link.zip'
        with zipfile.ZipFile(bad, 'w') as z:
            for i, data in rows:
                if i.filename.endswith('s2.pth'): i.external_attr = (stat.S_IFLNK | 0o777) << 16
                z.writestr(i, data)
        with self.assertRaises(ValueError): vd.build_bundle(image, bad, self.root / 'out', tools_commit=COMMIT, app_commit=APP_COMMIT, readme=readme, provenance={})
        (folder / 'reference.wav').write_bytes(b'not PCM')
        with self.assertRaises(ValueError): vd.build_voice_zip(folder, self.root / 'wrong.zip', notices=notices)

    def test_failed_output_keeps_originals_and_existing_destination(self):
        result = bundle(vd, self.root)
        before = {p.name: p.read_bytes() for p in (self.root / 'assets').iterdir()}
        with self.assertRaises(ValueError):
            vd.build_bundle(self.root / 'input.dmg', self.root / 'input.zip', self.root / 'assets',
                            tools_commit=COMMIT, app_commit=APP_COMMIT, readme=self.root / 'readme.md', provenance={})
        self.assertEqual(before, {p.name: p.read_bytes() for p in (self.root / 'assets').iterdir()})
        with self.assertRaises(ValueError):
            vd.build_bundle(self.root / 'input.dmg', self.root / 'input.zip', self.root / 'new',
                            tools_commit='bad', app_commit=APP_COMMIT, readme=self.root / 'readme.md', provenance={})
        self.assertFalse((self.root / 'new').exists())
        self.assertTrue((self.root / 'source-voice/s2.pth').is_file())

    def test_read_bundle_rejects_wrong_commit_metadata_digest_and_symlink(self):
        bundle(vd, self.root)
        with self.assertRaises(ValueError): vd.read_bundle(self.root / 'assets', version='1.0.0', tools_commit='c' * 40)
        p = self.root / 'assets/voice-assets.json'; raw = p.read_bytes()
        data = json.loads(raw); data['engine']['architecture'] = 'x86_64'; p.write_text(json.dumps(data))
        with self.assertRaises(ValueError): vd.read_bundle(self.root / 'assets', version='1.0.0', tools_commit=COMMIT)
        p.write_bytes(raw)
        checksum = self.root / 'assets' / (VOICE + '.sha256'); original = checksum.read_bytes()
        checksum.write_bytes(b'bad checksum')
        with self.assertRaises(ValueError): vd.read_bundle(self.root / 'assets', version='1.0.0', tools_commit=COMMIT)
        checksum.write_bytes(original); checksum.unlink(); checksum.symlink_to(self.root / 'readme.md')
        with self.assertRaises(ValueError): vd.read_bundle(self.root / 'assets', version='1.0.0', tools_commit=COMMIT)

    def test_package_cli_rejects_existing_output_without_touching_it(self):
        folder, image, readme, notices = inputs(self.root)
        out = self.root / 'exists'; out.mkdir(); (out / 'sentinel').write_bytes(b'keep')
        engine = engine_folder(self.root)
        proc = subprocess.run([sys.executable, str(ROOT / 'tools/package-voice-assets.py'),
            '--engine-dmg', str(image), '--voice', str(folder), '--output', str(out), '--commit', COMMIT,
            '--engine-package', str(engine), '--manifest-sha256', sha((engine / 'engine.json').read_bytes()),
            '--readme', str(readme), '--notices', str(notices)], capture_output=True)
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual((out / 'sentinel').read_bytes(), b'keep')

    def test_zip_creation_race_does_not_delete_someone_elses_file(self):
        folder, image, readme, notices = inputs(self.root)
        out = self.root / 'raced.zip'
        constructor = zipfile.ZipFile
        def race(path, mode, **kwargs):
            if mode == 'x':
                Path(path).write_bytes(b'someone else')
            return constructor(path, mode, **kwargs)
        with patch.object(vd.zipfile, 'ZipFile', side_effect=race), self.assertRaises((ValueError, OSError)):
            vd.build_voice_zip(folder, out, notices=notices)
        self.assertEqual(out.read_bytes(), b'someone else')

    def test_voice_metadata_and_riff_must_match_existing_app_contract(self):
        folder, image, readme, notices = inputs(self.root)
        manifest = json.loads((folder / 'voice.json').read_text())
        for index, changed in enumerate([dict(manifest, name=''),dict(manifest, promptText='x'*401),dict(manifest, suggestedCharacterID='../bad')]):
            (folder / 'voice.json').write_text(json.dumps(changed))
            with self.subTest(index=index), self.assertRaises(ValueError):
                vd.build_voice_zip(folder,self.root/('bad-text'+str(index)+'.zip'),notices=notices)
        data=(folder/'reference.wav').read_bytes()+b'trailing'
        (folder/'reference.wav').write_bytes(data)
        manifest['reference']={'file':'reference.wav','bytes':len(data),'sha256':sha(data)}
        (folder/'voice.json').write_text(json.dumps(manifest))
        with self.assertRaises(ValueError): vd.build_voice_zip(folder,self.root/'bad-riff.zip',notices=notices)

    def test_manifest_rejects_float_lookalike_lengths(self):
        bundle(vd,self.root)
        p=self.root/'assets/voice-assets.json';m=json.loads(p.read_text())
        m['assets'][0]['bytes']=float(m['assets'][0]['bytes']);p.write_text(json.dumps(m))
        with self.assertRaises(ValueError): vd.read_bundle(self.root/'assets',version='1.0.0',tools_commit=COMMIT)

    def test_engine_rejects_unlisted_root_files(self):
        engine=engine_folder(self.root);digest=sha((engine/'engine.json').read_bytes())
        (engine/'private.json').write_text('{}')
        with self.assertRaises(ValueError): vd.verify_engine_tree(engine,expected_manifest_sha256=digest)

    def test_package_cli_produces_valid_six_file_output(self):
        folder,image,readme,notices=inputs(self.root);engine=engine_folder(self.root)
        out=self.root/'cli-assets'
        proc=subprocess.run([sys.executable,str(ROOT/'tools/package-voice-assets.py'),
            '--engine-dmg',str(image),'--engine-package',str(engine),'--manifest-sha256',sha((engine/'engine.json').read_bytes()),
            '--voice',str(folder),'--output',str(out),'--commit',COMMIT,'--readme',str(readme),'--notices',str(notices)],capture_output=True)
        self.assertEqual(proc.returncode,0,proc.stderr.decode())
        self.assertEqual({a.name for a in vd.read_bundle(out,version='1.0.0',tools_commit=COMMIT).assets},FILES)


if __name__ == '__main__': unittest.main()
