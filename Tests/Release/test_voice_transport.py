import hashlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tools'))
from voice_distribution import snapshot_asset
from voice_release import VoiceGitHub, VoiceAPIError


class Response:
    def __init__(self,status=201,data=b'{"id":1}',headers=None):
        self.status=status;self.data=io.BytesIO(data);self.headers=headers or {}
    def read(self,n):
        if n<0: raise AssertionError('unbounded response read')
        return self.data.read(n)
    def getheader(self,name): return self.headers.get(name)

class Connection:
    def __init__(self,response,fail=False,on_send=None):
        self.response=response;self.fail=fail;self.on_send=on_send
        self.method=None;self.path=None;self.headers={};self.count=0;self.maximum=0
        self.digest=hashlib.sha256();self.closed=False
    def putrequest(self,method,path): self.method,self.path=method,path
    def putheader(self,key,value): self.headers[key.lower()]=str(value)
    def endheaders(self): pass
    def send(self,chunk):
        if self.fail: raise OSError('private network error with SECRET-TOKEN')
        self.count+=len(chunk);self.maximum=max(self.maximum,len(chunk));self.digest.update(chunk)
        if self.on_send: self.on_send()
    def getresponse(self): return self.response
    def close(self): self.closed=True

class VoiceTransportTests(unittest.TestCase):
    def setUp(self):
        t=tempfile.TemporaryDirectory();self.addCleanup(t.cleanup);self.root=Path(t.name)
        self.path=self.root/'asset.zip';self.path.write_bytes(b'x'*(2*1024*1024+17))
        self.asset=snapshot_asset(self.path);self.calls=[]

    def client(self,response=None,**kwargs):
        connection=Connection(response or Response(),**kwargs)
        def factory(host,timeout):
            self.calls.append((host,timeout,connection));return connection
        return VoiceGitHub('Resker666/YeShunguangPet-macOS','SECRET-TOKEN',connection_factory=factory),connection

    def test_upload_streams_bounded_chunks_and_exact_content_length(self):
        client,c=self.client();progress=[];client.progress=lambda sent,total:progress.append((sent,total))
        with patch.object(Path,'read_bytes',side_effect=AssertionError('whole-file read')):
            result=client.request('POST','releases/3/assets?name=asset.zip',asset=self.asset)
        self.assertEqual(result,{'id':1})
        self.assertEqual(self.calls[0][:2],('uploads.github.com',60))
        self.assertEqual(c.headers['content-length'],str(2*1024*1024+17))
        self.assertEqual(c.count,2*1024*1024+17);self.assertLessEqual(c.maximum,1024*1024)
        self.assertEqual(c.digest.hexdigest(),self.asset.sha256)
        self.assertEqual(progress[-1],(2*1024*1024+17,2*1024*1024+17));self.assertTrue(c.closed)

    def test_upload_failure_reports_state_without_retrying_post(self):
        client,c=self.client(fail=True)
        with self.assertRaises(VoiceAPIError) as caught: client.request('POST','releases/3/assets?name=asset.zip',asset=self.asset)
        self.assertEqual(len(self.calls),1);self.assertTrue(c.closed)
        self.assertNotIn('SECRET-TOKEN',str(caught.exception))

    def test_never_forwards_credentials_to_redirect_or_untrusted_upload_host(self):
        client,c=self.client(Response(302,b'secret server body',{'Location':'https://other.invalid/steal'}))
        with self.assertRaises(VoiceAPIError) as caught: client.request('GET','releases')
        self.assertEqual(caught.exception.status,302);self.assertEqual(len(self.calls),1)
        for bad in ['https://other.invalid/','../another','releases\r\nX-Evil: x','/releases']:
            with self.subTest(path=bad),self.assertRaises(ValueError): client.request('POST',bad,asset=self.asset)
        self.assertEqual(len(self.calls),1)

    def test_source_replaced_or_changed_during_send_is_not_success(self):
        changed=False
        def change():
            nonlocal changed
            if not changed:
                changed=True
                with self.path.open('r+b') as f: f.seek(1500000);f.write(b'new')
        client,c=self.client(on_send=change)
        with self.assertRaises((ValueError,VoiceAPIError)):
            client.request('POST','releases/3/assets?name=asset.zip',asset=self.asset)
        self.assertTrue(c.closed)

    def test_timeout_or_oversized_json_is_bounded(self):
        client,c=self.client(Response(200,b'x'*(1024*1024+1)))
        with self.assertRaises(VoiceAPIError):client.request('GET','releases')
        self.assertTrue(c.closed)
        client,c=self.client(fail=True)
        with self.assertRaises(VoiceAPIError):client.request('POST','releases',payload={'draft':True})
        self.assertTrue(c.closed)

    def test_fixed_upload_route_matches_asset_and_does_not_allow_payload(self):
        client,c=self.client()
        for route in ['releases/3/assets?name=other.zip','releases/3/assets?name=asset.zip&x=1','releases']:
            with self.subTest(route=route),self.assertRaises(ValueError):client.request('POST',route,asset=self.asset)
        with self.assertRaises(ValueError):client.request('POST','releases/3/assets?name=asset.zip',payload={},asset=self.asset)
        self.assertEqual(self.calls,[])

    def test_json_request_uses_api_host_and_sends_bounded_payload(self):
        client,c=self.client(Response(200,b'[]'))
        self.assertEqual(client.request('POST','releases',payload={'draft':True}),[])
        self.assertEqual(self.calls[0][0],'api.github.com')
        self.assertEqual(c.path,'/repos/Resker666/YeShunguangPet-macOS/releases')
        self.assertEqual(c.digest.hexdigest(),hashlib.sha256(json.dumps({'draft':True}).encode()).hexdigest())
        client,c=self.client()
        with self.assertRaises(ValueError):client.request('POST','releases',payload={'body':'x'*(1024*1024)})
        self.assertEqual(c.count,0)

    def test_error_status_never_includes_untrusted_response_or_credentials(self):
        client,c=self.client(Response(403,b'SECRET-TOKEN and private echoed text'))
        with self.assertRaises(VoiceAPIError) as caught:client.request('GET','releases')
        self.assertEqual(caught.exception.status,403)
        self.assertNotIn('SECRET',str(caught.exception));self.assertNotIn('echoed',str(caught.exception))


if __name__=='__main__':unittest.main()
