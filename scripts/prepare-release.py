#!/usr/bin/env python3
"""Validate this build's eight packages and prepare an unpublished GitHub Release.

No git ref creation, publication, asset replacement, or release deletion is performed.
The offline --check-only path does not require credentials or contact GitHub.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import sys
from urllib.error import HTTPError
from urllib.parse import quote
from urllib.request import Request, urlopen
import zipfile


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def collect_assets(directory, version, commit):
    if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', version):
        raise ValueError('Expected a numeric major.minor.patch version')
    if not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError('Expected a full source commit SHA')
    directory = Path(directory)
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError('Expected a real package directory')
    expected = {f'YeShunguangPet-{version}-macOS-{arch}.{suffix}{checksum}'
                for arch in ['arm64', 'x86_64'] for suffix in ['dmg', 'zip'] for checksum in ['', '.sha256']}
    if {p.name for p in directory.iterdir()} != expected:
        raise ValueError('Expected exactly eight versioned ARM/Intel package and checksum files')
    files = sorted(directory.iterdir())
    if any(p.is_symlink() or not p.is_file() or not 0 < p.stat().st_size <= 256 * 1024 * 1024 for p in files):
        raise ValueError('Package files must be nonempty ordinary files within the size limit')
    for arch in ['arm64', 'x86_64']:
        stem = f'YeShunguangPet-{version}-macOS-{arch}'
        for suffix in ['dmg', 'zip']:
            path = directory / (stem + '.' + suffix)
            checksum = Path(str(path) + '.sha256')
            if checksum.stat().st_size > 1024 or checksum.read_text() != digest(path) + '  ' + path.name + '\n':
                raise ValueError('Package checksum mismatch: ' + path.name)
        with zipfile.ZipFile(directory / (stem + '.zip')) as archive:
            base = stem + '/YeShunguangPet.app/Contents/'
            metadata = {}
            for name in ['Resources/build-info.json', 'Info.plist']:
                entries = [entry for entry in archive.infolist() if entry.filename == base + name]
                if len(entries) != 1 or not 0 < entries[0].file_size <= 65536:
                    raise ValueError('Missing, duplicate or oversized package metadata: ' + name)
                metadata[name] = archive.read(entries[0])
            info = json.loads(metadata['Resources/build-info.json'])
            if info != {'commit': commit, 'trackedChanges': False, 'architecture': arch} or info.get('trackedChanges') is not False:
                raise ValueError('Package source provenance mismatch: ' + arch)
            if plistlib.loads(metadata['Info.plist']).get('CFBundleShortVersionString') != version:
                raise ValueError('Package version mismatch: ' + arch)
    return files


class APIError(RuntimeError):
    def __init__(self, status):
        self.status = status
        super().__init__('GitHub API request failed (HTTP ' + str(status) + ')')


class GitHub:
    def __init__(self, repository, token):
        if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository) or not token:
            raise ValueError('Missing repository or GitHub token')
        self.repository = repository
        self.token = token

    def request(self, method, path, payload=None, asset=None):
        host = 'uploads.github.com' if asset else 'api.github.com'
        data = asset.read_bytes() if asset else json.dumps(payload).encode() if payload is not None else None
        headers = {'Authorization': 'Bearer ' + self.token, 'Accept': 'application/vnd.github+json',
                   'X-GitHub-Api-Version': '2026-03-10',
                   'Content-Type': 'application/octet-stream' if asset else 'application/json'}
        request = Request(f'https://{host}/repos/{self.repository}/{path}', data=data, headers=headers, method=method)
        try:
            with urlopen(request, timeout=120) as response:
                return json.load(response)
        except HTTPError as error:
            raise APIError(error.code) from None


def pages(api, path):
    for page in range(1, 101):
        rows = api.request('GET', f'{path}?per_page=100&page={page}')
        if not isinstance(rows, list):
            raise ValueError('Unexpected GitHub list response')
        yield from rows
        if len(rows) < 100:
            return
    raise ValueError('GitHub pagination limit reached; no release was selected implicitly')


def verify_tag(api, tag, commit):
    try:
        ref = api.request('GET', 'git/ref/tags/' + quote(tag, safe=''))
    except APIError as error:
        if error.status == 404:
            return  # The draft fixes target_commitish; this script never creates a ref.
        raise
    obj = ref['object']
    for _ in range(8):
        if obj['type'] == 'commit' and obj['sha'] == commit:
            return
        if obj['type'] != 'tag' or not re.fullmatch(r'[0-9a-f]{40}', obj['sha']):
            break
        obj = api.request('GET', 'git/tags/' + obj['sha'])['object']
    raise ValueError('Existing version tag points to a different source commit')


def verify_draft(release, tag, commit, body):
    if (release.get('draft') is not True or release.get('tag_name') != tag
            or release.get('target_commitish') != commit or release.get('body') != body
            or not isinstance(release.get('id'), int) or release['id'] <= 0):
        raise ValueError('Version already published or draft source/notes conflict; nothing was overwritten')


def prepare_release(api, directory, version, commit, notes):
    files = collect_assets(directory, version, commit)
    if not notes.strip() or len(notes.encode('utf-8')) > 65536:
        raise ValueError('Expected nonempty release notes within 64 KiB')
    tag = 'v' + version
    body = notes.rstrip() + f'\n\n构建来源：`{commit}`\n\n<!-- ysgpet-source:{commit} -->\n'
    verify_tag(api, tag, commit)
    matches = [r for r in pages(api, 'releases') if r.get('tag_name') == tag]
    if len(matches) > 1:
        raise ValueError('More than one release exists for this version')
    release = matches[0] if matches else api.request('POST', 'releases', payload={
        'tag_name': tag, 'target_commitish': commit, 'name': 'YeShunguangPet ' + version,
        'body': body, 'draft': True, 'prerelease': False, 'make_latest': 'false'})
    verify_draft(release, tag, commit, body)
    route = 'releases/' + str(release['id'])
    expected = {p.name: {'name': p.name, 'size': p.stat().st_size, 'digest': 'sha256:' + digest(p)} for p in files}

    def check_assets():
        found = {}
        for asset in pages(api, route + '/assets'):
            name = asset.get('name')
            if name not in expected or name in found or asset.get('state') != 'uploaded':
                raise ValueError('Unexpected or unfinished draft asset; no replacement attempted')
            if any(asset.get(k) != v for k, v in expected[name].items()):
                raise ValueError('Draft asset content differs; no replacement attempted: ' + name)
            found[name] = asset
        return found

    found = check_assets()
    for path in files:
        if path.name not in found:
            verify_draft(api.request('GET', route), tag, commit, body)
            api.request('POST', route + '/assets?name=' + quote(path.name, safe=''), asset=path)
    if set(check_assets()) != set(expected):
        raise ValueError('Draft is missing package assets')
    release = api.request('GET', route)
    verify_draft(release, tag, commit, body)
    verify_tag(api, tag, commit)
    return release


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--assets', type=Path, required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--commit', required=True)
    parser.add_argument('--notes', type=Path)
    parser.add_argument('--check-only', action='store_true')
    args = parser.parse_args()
    files = collect_assets(args.assets, args.version, args.commit)
    if args.check_only:
        print(json.dumps({'commit': args.commit, 'version': args.version, 'assets': [p.name for p in files]}))
        return
    if os.environ.get('GITHUB_EVENT_NAME') != 'workflow_dispatch' or os.environ.get('GITHUB_REF') != 'refs/heads/main':
        raise ValueError('Release draft preparation requires an explicit workflow dispatch on main')
    if not args.notes or not args.notes.is_file() or args.notes.stat().st_size > 65536:
        raise ValueError('Missing release notes for this version')
    api = GitHub(os.environ.get('GITHUB_REPOSITORY', ''), os.environ.get('GH_TOKEN', ''))
    result = prepare_release(api, args.assets, args.version, args.commit, args.notes.read_text())
    print(json.dumps({'draft': True, 'url': result['html_url'], 'commit': args.commit, 'version': args.version}))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, zipfile.BadZipFile, APIError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
