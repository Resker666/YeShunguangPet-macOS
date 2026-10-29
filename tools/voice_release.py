"""Explicit optional voice releases; no credentials or network at import time."""
from __future__ import annotations

import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import tempfile
from contextlib import closing
from urllib.parse import quote, unquote, urlsplit
from urllib.request import Request, HTTPRedirectHandler, build_opener
from urllib.error import URLError

from voice_distribution import CHUNK, AssetRecord, checked_reader, valid_asset_size, _pairs, read_bundle, _commit_directory

MAX_JSON=1024*1024

class VoiceAPIError(RuntimeError):
    def __init__(self,status,message='GitHub request failed'):
        self.status=status
        super().__init__(message+' (HTTP '+str(status)+')')

class VoiceGitHub:
    def __init__(self,repository,token,*,connection_factory=http.client.HTTPSConnection,progress=None):
        if not isinstance(repository,str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*',repository):
            raise ValueError('invalid GitHub repository')
        if not isinstance(token,str) or not token or any(not 33<=ord(c)<=126 for c in token):
            raise ValueError('missing or invalid active GitHub credential')
        self.repository=repository;self._token=token
        self.connection_factory=connection_factory;self.progress=progress or (lambda sent,total:None)

    def request(self,method,path,payload=None,asset=None):
        if method not in {'GET','POST','PATCH'} or not isinstance(path,str) or not path or path.startswith('/') or any(c in path for c in '\r\n\\#') or '://' in path or '..' in unquote(path.split('?',1)[0]).split('/'):
            raise ValueError('invalid GitHub route')
        if payload is not None and (asset is not None or method=='GET'): raise ValueError('invalid request body')
        host='api.github.com';data=b''
        if asset is not None:
            if not isinstance(asset,AssetRecord) or not valid_asset_size(asset.bytes) or not re.fullmatch(r'[0-9a-f]{64}',asset.sha256) or '/' in asset.name or '\\' in asset.name:
                raise ValueError('invalid asset snapshot')
            if method!='POST' or not re.fullmatch(r'releases/[1-9][0-9]*/assets\?name='+re.escape(quote(asset.name,safe='')),path):
                raise ValueError('asset route does not match its snapshot')
            host='uploads.github.com'
        elif payload is not None:
            data=json.dumps(payload).encode('utf-8')
            if len(data)>MAX_JSON: raise ValueError('request JSON size limit')
        length=asset.bytes if asset is not None else len(data)
        connection=None
        try:
            connection=self.connection_factory(host,timeout=60)
            connection.putrequest(method,'/repos/'+self.repository+'/'+path)
            for k,v in {'Authorization':'Bearer '+self._token,'Accept':'application/vnd.github+json',
                        'User-Agent':'YeShunguangPet-Voice-Release','X-GitHub-Api-Version':'2026-03-10',
                        'Content-Type':'application/octet-stream' if asset is not None else 'application/json',
                        'Content-Length':str(length)}.items(): connection.putheader(k,v)
            if asset is not None:
                with checked_reader(asset.path) as (f,info):
                    if info.st_size!=length: raise ValueError('asset changed before upload')
                    connection.endheaders()
                    remaining=length;h=hashlib.sha256()
                    while remaining:
                        chunk=f.read(min(CHUNK,remaining))
                        if not chunk: raise ValueError('asset truncated during upload')
                        connection.send(chunk);h.update(chunk);remaining-=len(chunk)
                        self.progress(length-remaining,length)
                    if f.read(1) or h.hexdigest()!=asset.sha256: raise ValueError('asset changed during upload')
            else:
                connection.endheaders()
                if data: connection.send(data)
            response=connection.getresponse()
            if not 200<=response.status<300: raise VoiceAPIError(response.status)
            raw=response.read(MAX_JSON+1)
            if len(raw)>MAX_JSON: raise VoiceAPIError(response.status,'GitHub JSON size limit')
            try:
                result=json.loads(raw,object_pairs_hook=_pairs,
                                  parse_constant=lambda value: (_ for _ in ()).throw(ValueError()))
            except (ValueError,UnicodeError,RecursionError): raise VoiceAPIError(response.status,'Invalid GitHub JSON') from None
            if not isinstance(result,(dict,list)): raise VoiceAPIError(response.status,'Unexpected GitHub JSON')
            return result
        except (OSError,http.client.HTTPException):
            raise VoiceAPIError(0,'Transport interrupted; inspect the same draft before retrying') from None
        finally:
            if connection is not None: connection.close()

REPOSITORY='Resker666/YeShunguangPet-macOS'
TAG='voice-assets-v1.0.0'
TITLE='本地语音资源1.0.0（M系列预览）'

def _current(bundle):
    folder=bundle.assets[0].path.parent
    checked=read_bundle(folder,version=bundle.version,tools_commit=bundle.tools_commit)
    if checked.assets!=bundle.assets or checked.manifest!=bundle.manifest: raise ValueError('resource snapshot changed; prepare it again')

def _body(bundle,notes):
    if not isinstance(notes,str) or not notes.strip() or len(notes.encode())>65536: raise ValueError('release notes must be nonempty and within 64 KiB')
    digest=next(a.sha256 for a in bundle.assets if a.name=='voice-assets.json')
    return notes.rstrip()+'\n\n资源工具来源：`'+bundle.tools_commit+'`\n\n<!-- ysgpet-voice-source:'+bundle.tools_commit+' -->\n<!-- ysgpet-voice-manifest:'+digest+' -->\n'

def _pages(api,path):
    for page in range(1,101):
        rows=api.request('GET',path+'?per_page=100&page='+str(page))
        if not isinstance(rows,list) or len(rows)>100 or any(not isinstance(r,dict) for r in rows): raise ValueError('invalid GitHub page')
        yield from rows
        if len(rows)<100:return
    raise ValueError('GitHub pagination limit reached')

def _tag(api,commit,*,required=False):
    try:ref=api.request('GET','git/ref/tags/'+quote(TAG,safe=''))
    except VoiceAPIError as error:
        if error.status==404 and not required:return False
        raise
    if not isinstance(ref,dict) or not isinstance(ref.get('object'),dict):raise ValueError('invalid GitHub tag metadata')
    obj=ref['object']
    for depth in range(9):
        if not isinstance(obj,dict) or not isinstance(obj.get('sha'),str) or not re.fullmatch('[0-9a-f]{40}',obj['sha']):break
        if obj.get('type')=='commit':
            if obj['sha']==commit:return True
            break
        if obj.get('type')!='tag' or depth==8:break
        obj=api.request('GET','git/tags/'+obj['sha']).get('object')
    raise ValueError('resource tag points to a different or unsupported source')

def _release(value,bundle,body):
    if not isinstance(value,dict) or type(value.get('id')) is not int or value['id']<=0 or type(value.get('draft')) is not bool or value.get('prerelease') is not True or value.get('tag_name')!=TAG or value.get('target_commitish')!=bundle.tools_commit or value.get('body')!=body or value.get('name')!=TITLE:
        raise ValueError('resource release state, source or notes conflict; nothing overwritten')

def _asset_rows(rows,bundle,*,complete):
    wanted={a.name:a for a in bundle.assets};found={}
    for value in rows:
        if not isinstance(value,dict):raise ValueError('invalid remote asset')
        name=value.get('name')
        if not isinstance(name,str) or name not in wanted or name in found:raise ValueError('unexpected or duplicate remote resource asset')
        expected=wanted[name]
        if type(value.get('id')) is not int or value['id']<=0 or value.get('state')!='uploaded' or type(value.get('size')) is not int or value['size']!=expected.bytes or value.get('digest')!='sha256:'+expected.sha256:
            raise ValueError('remote asset incomplete or conflicting; inspect the same draft without replacing files')
        found[name]=value
    if complete and set(found)!=set(wanted):raise ValueError('resource release is missing verified attachments')
    return found

def _remote_assets(api,release,bundle,*,complete):
    return _asset_rows(_pages(api,'releases/'+str(release['id'])+'/assets'),bundle,complete=complete)

def prepare_voice_release(api,bundle,notes):
    _current(bundle);body=_body(bundle,notes);_tag(api,bundle.tools_commit)
    matching=[r for r in _pages(api,'releases') if r.get('tag_name')==TAG]
    if len(matching)>1:raise ValueError('multiple releases use the resource tag')
    release=matching[0] if matching else api.request('POST','releases',payload={
        'tag_name':TAG,'target_commitish':bundle.tools_commit,'name':TITLE,'body':body,
        'draft':True,'prerelease':True,'make_latest':'false'})
    _release(release,bundle,body)
    found=_remote_assets(api,release,bundle,complete=not release['draft'])
    if not release['draft']:
        _tag(api,bundle.tools_commit,required=True)
    else:
        for asset in bundle.assets:
            if asset.name not in found:
                api.request('POST','releases/'+str(release['id'])+'/assets?name='+quote(asset.name,safe=''),asset=asset)
    fresh=api.request('GET','releases/'+str(release['id']));_release(fresh,bundle,body)
    if fresh['draft']!=release['draft']:raise ValueError('resource release changed while preparing')
    fresh['assets']=list(_remote_assets(api,fresh,bundle,complete=True).values())
    _current(bundle)
    return fresh

def _latest(api):
    try:latest=api.request('GET','releases/latest')
    except VoiceAPIError as error:
        if error.status==404:return None
        raise
    if not isinstance(latest,dict) or latest.get('tag_name')==TAG or latest.get('draft') is not False or latest.get('prerelease') is not False:
        raise ValueError('normal App Latest is not a stable App release')
    return latest.get('id'),latest.get('tag_name')

def publish_voice_release(api,bundle,notes):
    release=prepare_voice_release(api,bundle,notes)
    before=_latest(api)
    if release['draft']:
        # Never publish based merely on successful upload responses.
        current=api.request('GET','releases/'+str(release['id']));_release(current,bundle,_body(bundle,notes))
        if current['draft'] is not True:raise ValueError('draft changed before publication')
        _tag(api,bundle.tools_commit)
        _remote_assets(api,current,bundle,complete=True);_current(bundle)
        api.request('PATCH','releases/'+str(release['id']),payload={'draft':False,'prerelease':True,'make_latest':'false'})
    fresh=api.request('GET','releases/'+str(release['id']));_release(fresh,bundle,_body(bundle,notes))
    if fresh['draft'] is not False or not fresh.get('published_at'):raise ValueError('resource release is not confirmed public')
    _tag(api,bundle.tools_commit,required=True)
    fresh['assets']=list(_remote_assets(api,fresh,bundle,complete=True).values())
    if _latest(api)!=before:raise ValueError('App Latest changed during publication; inspect its actual source')
    return fresh

def _download_url_allowed(url):
    value=urlsplit(url)
    return value.scheme=='https' and value.hostname in {'github.com','release-assets.githubusercontent.com','objects.githubusercontent.com'} and not value.username and not value.password and not value.fragment and value.port in (None,443)

class AnonymousRedirects(HTTPRedirectHandler):
    def redirect_request(self,request,fp,code,message,headers,newurl):
        if not _download_url_allowed(newurl):raise ValueError('untrusted resource download redirect')
        redirected=super().redirect_request(request,fp,code,message,headers,newurl)
        if redirected:
            redirected.remove_header('Authorization');redirected.remove_header('Cookie')
        return redirected

def verify_public_downloads(bundle,release,destination,*,opener=None):
    destination=Path(destination)
    if os.path.lexists(destination):raise ValueError('download destination already exists')
    if not isinstance(release,dict) or release.get('draft') is not False or release.get('prerelease') is not True or release.get('tag_name')!=TAG or release.get('target_commitish')!=bundle.tools_commit:
        raise ValueError('resource release is not public at the expected source')
    _asset_rows(release.get('assets',[]),bundle,complete=True)
    opener=opener or build_opener(AnonymousRedirects()).open
    destination.parent.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.voice-download-',dir=destination.parent) as temporary:
        stage=Path(temporary)/'files';stage.mkdir()
        for asset in bundle.assets:
            url='https://github.com/'+REPOSITORY+'/releases/download/'+TAG+'/'+quote(asset.name,safe='')
            request=Request(url,headers={'User-Agent':'YeShunguangPet-Voice-Verify','Accept':'application/octet-stream'})
            total=0;h=hashlib.sha256()
            try:
                with closing(opener(request,timeout=60)) as response,(stage/asset.name).open('xb') as output:
                    if response.status!=200:raise ValueError('anonymous resource request failed')
                    for chunk in iter(lambda:response.read(CHUNK),b''):
                        total+=len(chunk)
                        if total>asset.bytes:raise ValueError('download exceeds expected size')
                        output.write(chunk);h.update(chunk)
            except (OSError,URLError,http.client.HTTPException):raise ValueError('anonymous resource download interrupted') from None
            if total!=asset.bytes or h.hexdigest()!=asset.sha256:raise ValueError('anonymous resource digest or size mismatch')
        read_bundle(stage,version=bundle.version,tools_commit=bundle.tools_commit)
        _commit_directory(stage,destination)
    return {'verifiedFiles':len(bundle.assets),'tag':TAG,'toolsCommit':bundle.tools_commit,'anonymous':True}
