import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from contextlib import redirect_stdout,redirect_stderr
from urllib.parse import parse_qs
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tools'))
import voice_distribution as vd
import voice_release as vr
from voice_fixtures import COMMIT, FILES, bundle

TAG='voice-assets-v1.0.0'
REPO='Resker666/YeShunguangPet-macOS'

class API:
    def __init__(self):
        self.releases=[];self.assets=[];self.ref=None;self.calls=[];self.fail_name=None;self.fail_after_store=False
        self.latest={'id':10,'tag_name':'v0.1.19','draft':False,'prerelease':False}
    def request(self,method,path,payload=None,asset=None):
        self.calls.append((method,path,copy.deepcopy(payload),asset.name if asset else None))
        if method=='GET':
            if path.startswith('git/ref/tags/'):
                if self.ref is None: raise vr.VoiceAPIError(404)
                return {'object':copy.deepcopy(self.ref)}
            if path.startswith('releases?'):return copy.deepcopy(self.releases) if 'page=1' in path else []
            if path=='releases/latest':return copy.deepcopy(self.latest)
            if path.startswith('releases/7/assets?'):return copy.deepcopy(self.assets) if 'page=1' in path else []
            if path=='releases/7':
                result=copy.deepcopy(self.releases[0]);result['assets']=copy.deepcopy(self.assets);return result
        if method=='POST' and path=='releases':
            r=copy.deepcopy(payload);r.update(id=7,html_url='https://github.com/'+REPO+'/releases/tag/'+TAG,published_at=None,assets=[])
            self.releases.append(r);return copy.deepcopy(r)
        if method=='POST' and path.startswith('releases/7/assets?'):
            if self.fail_name==asset.name and not self.fail_after_store:
                self.fail_name=None;raise vr.VoiceAPIError(0)
            row={'id':100+len(self.assets),'name':asset.name,'state':'uploaded','size':asset.bytes,'digest':'sha256:'+asset.sha256,
                 'browser_download_url':'https://github.com/'+REPO+'/releases/download/'+TAG+'/'+asset.name}
            self.assets.append(row)
            if self.fail_name==asset.name:
                self.fail_name=None;raise vr.VoiceAPIError(0)
            return copy.deepcopy(row)
        if method=='PATCH' and path=='releases/7':
            self.releases[0].update(payload);self.releases[0]['published_at']='2026-10-29T12:00:00Z'
            self.ref={'type':'commit','sha':COMMIT}
            return copy.deepcopy(self.releases[0])
        raise AssertionError((method,path))

class Download:
    def __init__(self,data):self.source=io.BytesIO(data);self.status=200
    def read(self,n):
        if not 0<n<=1024*1024:raise AssertionError('unbounded download')
        return self.source.read(n)
    def close(self):self.source.close()

class VoiceReleaseTests(unittest.TestCase):
    def setUp(self):
        t=tempfile.TemporaryDirectory();self.addCleanup(t.cleanup);self.root=Path(t.name)
        self.bundle=bundle(vd,self.root);self.api=API();self.notes='M 系列语音资源预览。来源未核实项见附件。'

    def test_resource_draft_is_prerelease_not_latest_and_pins_commit(self):
        r=vr.prepare_voice_release(self.api,self.bundle,self.notes)
        self.assertTrue(r['draft']);self.assertTrue(r['prerelease']);self.assertEqual(r['tag_name'],TAG)
        self.assertEqual(r['target_commitish'],COMMIT);self.assertEqual({a['name'] for a in self.api.assets},FILES)
        posts=[c for c in self.api.calls if c[0]=='POST' and c[1]=='releases']
        self.assertEqual(posts[0][2]['make_latest'],'false')
        self.assertEqual(self.api.latest['tag_name'],'v0.1.19')

    def test_retry_only_uploads_missing_files_after_interrupt(self):
        ordered=sorted(FILES);self.api.fail_name=ordered[2];self.api.fail_after_store=True
        with self.assertRaises(vr.VoiceAPIError):vr.prepare_voice_release(self.api,self.bundle,self.notes)
        self.assertEqual(len(self.api.assets),3)
        vr.prepare_voice_release(self.api,self.bundle,self.notes)
        self.assertEqual(len(self.api.releases),1);self.assertEqual(len(self.api.assets),6)
        attempts=[c[3] for c in self.api.calls if c[0]=='POST' and c[3]]
        self.assertEqual(len(attempts),6)

    def test_conflicting_tag_notes_source_or_assets_are_never_overwritten(self):
        self.api.ref={'type':'commit','sha':'b'*40}
        with self.assertRaises(ValueError):vr.prepare_voice_release(self.api,self.bundle,self.notes)
        self.assertFalse(any(c[0]!='GET' for c in self.api.calls))
        self.api.ref=None;vr.prepare_voice_release(self.api,self.bundle,self.notes)
        before=len(self.api.calls)
        with self.assertRaises(ValueError):vr.prepare_voice_release(self.api,self.bundle,'changed notes')
        self.assertTrue(all(c[0]=='GET' for c in self.api.calls[before:]))
        self.api.assets[0]['digest']='sha256:'+'0'*64
        before=len(self.api.calls)
        with self.assertRaises(ValueError):vr.prepare_voice_release(self.api,self.bundle,self.notes)
        self.assertTrue(all(c[0]=='GET' for c in self.api.calls[before:]))

    def test_starter_asset_blocks_without_deletion(self):
        vr.prepare_voice_release(self.api,self.bundle,self.notes)
        self.api.assets[0]['state']='starter';before=len(self.api.calls)
        with self.assertRaises(ValueError):vr.prepare_voice_release(self.api,self.bundle,self.notes)
        self.assertTrue(all(c[0]=='GET' for c in self.api.calls[before:]))
        self.assertEqual(len(self.api.assets),6)

    def test_publish_requires_rechecked_complete_release_and_preserves_latest(self):
        r=vr.publish_voice_release(self.api,self.bundle,self.notes)
        self.assertFalse(r['draft']);self.assertTrue(r['prerelease']);self.assertEqual(self.api.ref['sha'],COMMIT)
        self.assertEqual(self.api.latest['tag_name'],'v0.1.19')
        mutations=len([c for c in self.api.calls if c[0]!='GET'])
        vr.publish_voice_release(self.api,self.bundle,self.notes)
        self.assertEqual(len([c for c in self.api.calls if c[0]!='GET']),mutations)

    def test_source_changed_before_network_is_rejected(self):
        (self.root/'assets/安装说明.md').write_text('changed')
        with self.assertRaises(ValueError):vr.prepare_voice_release(self.api,self.bundle,self.notes)
        self.assertEqual(self.api.calls,[])

    def test_default_and_check_only_never_read_credentials_or_contact_api(self):
        spec=importlib.util.spec_from_file_location('voice_cli',ROOT/'scripts/prepare-voice-release.py')
        cli=importlib.util.module_from_spec(spec);spec.loader.exec_module(cli)
        for mode in [[],['--check-only']]:
            with patch.object(cli,'VoiceGitHub',side_effect=AssertionError('network setup')),patch.dict(cli.os.environ,{'GH_TOKEN':'\ninvalid'}),redirect_stdout(io.StringIO()) as output:
                cli.main(['--assets',str(self.root/'assets'),'--version','1.0.0','--commit',COMMIT]+mode)
            self.assertEqual(json.loads(output.getvalue())['commit'],COMMIT)
        with redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):cli.main(['--assets',str(self.root/'assets'),'--version','1.0.0','--commit',COMMIT,'--prepare-draft','--publish'])

    def test_public_downloads_use_anonymous_urls_and_match_snapshot(self):
        release=vr.publish_voice_release(self.api,self.bundle,self.notes);calls=[]
        contents={a.name:a.path.read_bytes() for a in self.bundle.assets}
        def opener(request,timeout):
            calls.append(request)
            from urllib.parse import unquote
            name=unquote(request.full_url.rsplit('/',1)[1])
            return Download(contents[name])
        result=vr.verify_public_downloads(self.bundle,release,self.root/'download',opener=opener)
        self.assertEqual({p.name for p in (self.root/'download').iterdir()},FILES)
        self.assertEqual(result['verifiedFiles'],6)
        self.assertEqual(len(calls),6)
        for req in calls:
            self.assertTrue(req.full_url.startswith('https://github.com/'+REPO+'/releases/download/'+TAG+'/'))
            self.assertFalse(req.has_header('Authorization'));self.assertFalse(req.has_header('Cookie'))

    def test_incomplete_or_bad_download_keeps_existing_files(self):
        release=vr.publish_voice_release(self.api,self.bundle,self.notes)
        with self.assertRaises(ValueError):vr.verify_public_downloads(self.bundle,release,self.root/'bad',opener=lambda req,timeout:Download(b'bad'))
        self.assertFalse((self.root/'bad').exists())
        existing=self.root/'existing';existing.mkdir();(existing/'sentinel').write_bytes(b'keep')
        with self.assertRaises(ValueError):vr.verify_public_downloads(self.bundle,release,existing,opener=lambda *a,**k: self.fail('network called'))
        self.assertEqual((existing/'sentinel').read_bytes(),b'keep')

    def test_malformed_tag_metadata_is_rejected_without_writing(self):
        original=self.api.request
        def malformed(method,path,**kwargs):
            if path.startswith('git/ref/'):return {}
            return original(method,path,**kwargs)
        self.api.request=malformed
        with self.assertRaises(ValueError):vr.prepare_voice_release(self.api,self.bundle,self.notes)
        self.assertFalse(any(c[0]!='GET' for c in self.api.calls))

    def test_duplicate_and_unexpected_remote_assets_are_rejected(self):
        vr.prepare_voice_release(self.api,self.bundle,self.notes)
        original=copy.deepcopy(self.api.assets)
        for extra in [copy.deepcopy(original[0]),dict(original[0],name='unexpected.pth')]:
            self.api.assets=original+[extra];before=len(self.api.calls)
            with self.assertRaises(ValueError):vr.publish_voice_release(self.api,self.bundle,self.notes)
            self.assertTrue(all(c[0]=='GET' for c in self.api.calls[before:]))

    def test_pagination_and_annotated_tag_loops_are_bounded(self):
        def forever(method,path,**kwargs):
            if path.startswith('git/ref/'):return {'object':{'type':'tag','sha':'c'*40}}
            if path.startswith('git/tags/'):return {'object':{'type':'tag','sha':'c'*40}}
            self.fail('unexpected route')
        self.api.request=forever
        with self.assertRaises(ValueError):vr.prepare_voice_release(self.api,self.bundle,self.notes)
        def pages(method,path,**kwargs):
            if path.startswith('git/ref/'):raise vr.VoiceAPIError(404)
            if path.startswith('releases?'):return [{'tag_name':'another'} for _ in range(100)]
            self.fail('unexpected write')
        self.api.request=pages
        with self.assertRaises(ValueError):vr.prepare_voice_release(self.api,self.bundle,self.notes)

    def test_anonymous_redirects_reject_untrusted_host_and_drop_credentials(self):
        from urllib.request import Request
        redirect=vr.AnonymousRedirects();request=Request('https://github.com/'+REPO+'/releases/download/'+TAG+'/asset',headers={'Authorization':'secret','Cookie':'secret'})
        with self.assertRaises(ValueError):redirect.redirect_request(request,None,302,'',{},'https://other.invalid/asset')
        result=redirect.redirect_request(request,None,302,'',{},'https://release-assets.githubusercontent.com/test?sig=opaque')
        self.assertFalse(result.has_header('Authorization'));self.assertFalse(result.has_header('Cookie'))


if __name__=='__main__':unittest.main()
