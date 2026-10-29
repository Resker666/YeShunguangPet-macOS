"""Explicit optional voice releases; no credentials or network at import time."""
from __future__ import annotations

import hashlib
import http.client
import json
import re
from urllib.parse import quote, unquote

from voice_distribution import CHUNK, AssetRecord, checked_reader, valid_asset_size, _pairs

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
