"""Offline packaging and read-only validation of optional voice release assets."""
from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass
import ctypes
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import tempfile
import unicodedata
import zipfile

ENGINE = 'YeShunguangPet-VoiceEngine-1.0.0-macOS-arm64.dmg'
VOICE = 'YeShunguangPet-Voice-hutao-pilot-e1.zip'
FILES = frozenset((ENGINE, ENGINE+'.sha256', VOICE, VOICE+'.sha256', 'voice-assets.json', '安装说明.md'))
PROFILE = 'gpt-sovits-v2proplus-cpu1'
APP_COMMIT = '375ff361e02de30f5ccab8a03e9f5b3412d44800'
UPSTREAM = 'b4570b876f5c086819ba84e3215472733c6a7b70'
MANIFEST_SHA = 'c7a1a53bf9de6d45dc506901296a8946ce3c62d7b5b2079e0ab564640ee5d23d'
MAX_ASSET = 2**31-1
CHUNK = 1024*1024

@dataclass(frozen=True)
class AssetRecord:
    name: str
    path: Path
    bytes: int
    sha256: str

@dataclass(frozen=True)
class VoiceBundle:
    version: str
    tools_commit: str
    manifest: dict
    assets: tuple[AssetRecord, ...]

def valid_asset_size(size):
    return type(size) is int and 0 < size < 2**31

def _stamp(s):
    return s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns, s.st_mode

@contextmanager
def checked_reader(path, maximum=MAX_ASSET):
    path = Path(path)
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError as error:
        raise ValueError('file unavailable: '+path.name) from error
    with os.fdopen(fd, 'rb') as f:
        try:
            before = os.fstat(f.fileno())
        except OSError as error:
            raise ValueError('file unavailable: '+path.name) from error
        if not stat.S_ISREG(before.st_mode) or not 0 <= before.st_size <= maximum:
            raise ValueError('invalid file type or size: '+path.name)
        # Exceptions in the consumer (e.g. a failed network send) belong to it.
        yield f, before
        try:
            if _stamp(before) != _stamp(os.fstat(f.fileno())) or _stamp(before) != _stamp(path.lstat()):
                raise ValueError('source changed while reading: '+path.name)
        except OSError as error:
            raise ValueError('file unavailable: '+path.name) from error

def snapshot_asset(path):
    path = Path(path)
    with checked_reader(path) as (f, info):
        if not valid_asset_size(info.st_size): raise ValueError('invalid asset size')
        h = hashlib.sha256(); total = 0
        for chunk in iter(lambda:f.read(CHUNK), b''):
            total += len(chunk)
            if total > info.st_size: raise ValueError('source grew during read')
            h.update(chunk)
        if total != info.st_size: raise ValueError('source truncated during read')
    return AssetRecord(path.name, path, total, h.hexdigest())

def _read(path, maximum):
    with checked_reader(path, maximum) as (f, info):
        data = f.read(maximum+1)
        if len(data) != info.st_size: raise ValueError('invalid file length')
    return data

def _pairs(rows):
    result = {}
    for k,v in rows:
        if k in result: raise ValueError('duplicate JSON key')
        result[k] = v
    return result

def decode_json(data, maximum):
    if not 0 < len(data) <= maximum: raise ValueError('JSON size limit')
    try:
        result = json.loads(data, object_pairs_hook=_pairs,
                            parse_constant=lambda value: (_ for _ in ()).throw(ValueError('invalid JSON number')))
    except (UnicodeError, json.JSONDecodeError, RecursionError) as error:
        raise ValueError('invalid JSON') from error
    if not isinstance(result, dict): raise ValueError('expected JSON object')
    return result

def _hex(value, length):
    return isinstance(value, str) and re.fullmatch('[0-9a-f]{'+str(length)+'}', value) is not None

def _integer(value, low, high):
    return type(value) is int and low <= value <= high

def _directory(path):
    if not stat.S_ISDIR(Path(path).lstat().st_mode): raise ValueError('expected real directory')

def verify_engine_tree(folder, *, expected_manifest_sha256):
    folder = Path(folder); _directory(folder)
    if {p.name for p in folder.iterdir()} - {'.DS_Store'} != {'engine.json','payload'}:
        raise ValueError('unexpected engine root files')
    raw = _read(folder/'engine.json', 16*1024*1024)
    if not _hex(expected_manifest_sha256, 64) or hashlib.sha256(raw).hexdigest() != expected_manifest_sha256:
        raise ValueError('engine manifest identity mismatch')
    m = decode_json(raw, 16*1024*1024)
    if set(m) != {'schemaVersion','id','version','name','architecture','minimumOS','pythonVersion','profile','sourceCommit','files'}:
        raise ValueError('unexpected engine metadata')
    if type(m['schemaVersion']) is not int or m['schemaVersion'] != 1 or m['architecture'] != 'arm64' or m['minimumOS'] != '14.0' or m['profile'] != PROFILE or m['sourceCommit'] != UPSTREAM:
        raise ValueError('incompatible engine metadata')
    if not isinstance(m['files'], list) or not 1 <= len(m['files']) <= 100000: raise ValueError('invalid engine inventory')
    payload = folder/'payload'; _directory(payload)
    actual = set()
    for parent, dirs, files in os.walk(payload, followlinks=False):
        for name in dirs: _directory(Path(parent)/name)
        actual.update((Path(parent)/name).relative_to(payload).as_posix() for name in files)
    expected = set(); total = 0
    for row in m['files']:
        if not isinstance(row, dict) or set(row) != {'path','bytes','sha256','executable'}: raise ValueError('invalid engine record')
        name = row['path']
        if not isinstance(name,str) or len(name)>2048 or '\\' in name or len(name.split('/'))>32 or any(p in ('','.','..') for p in name.split('/')):
            raise ValueError('unsafe engine path')
        if name in expected or not _integer(row['bytes'],0,2**31) or not _hex(row['sha256'],64) or type(row['executable']) is not bool:
            raise ValueError('invalid engine record values')
        expected.add(name); p = payload/name
        parent = p.parent
        while parent != payload:
            _directory(parent); parent = parent.parent
        with checked_reader(p, 2**31) as (f, s):
            if s.st_size != row['bytes'] or bool(s.st_mode & 0o111) != row['executable']: raise ValueError('engine size or executable mismatch')
            h = hashlib.sha256()
            for chunk in iter(lambda:f.read(CHUNK), b''): h.update(chunk)
            if h.hexdigest() != row['sha256']: raise ValueError('engine digest mismatch')
        total += row['bytes']
        if total > 12*1024**3: raise ValueError('engine total size limit')
    if actual != expected or hashlib.sha256(_read(folder/'engine.json',16*1024*1024)).hexdigest() != expected_manifest_sha256:
        raise ValueError('engine inventory or manifest changed')
    return {'files':len(expected), 'payloadBytes':total, 'manifestSHA256':expected_manifest_sha256}

def _voice_manifest(raw):
    m = decode_json(raw,16384)
    if set(m) - {'schemaVersion','id','name','language','engineProfile','promptText','suggestedCharacterID','model','reference'}:
        raise ValueError('unexpected voice field')
    if type(m.get('schemaVersion')) is not int or m.get('schemaVersion') != 1 or m.get('id') != 'hutao-pilot-e1' or m.get('language') != 'zh-CN' or m.get('engineProfile') != PROFILE:
        raise ValueError('incompatible voice')
    for key, maximum in [('name',80),('promptText',400)]:
        value=m.get(key)
        if not isinstance(value,str) or not value.strip() or len(value.encode('utf-16-le'))//2>maximum or any(unicodedata.category(c)=='Cc' for c in value):
            raise ValueError('invalid voice text')
    suggested=m.get('suggestedCharacterID')
    if suggested is not None and (not isinstance(suggested,str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,64}',suggested)):
        raise ValueError('invalid suggested character ID')
    for key, filename, maximum in [('model','s2.pth',268435456),('reference','reference.wav',1048576)]:
        r = m.get(key)
        if not isinstance(r,dict) or set(r) != {'file','bytes','sha256'} or r['file'] != filename or not _integer(r['bytes'],1,maximum) or not _hex(r['sha256'],64):
            raise ValueError('invalid voice asset')
    return m

def _pcm(data):
    def integer(start,count): return int.from_bytes(data[start:start+count],'little')
    if len(data)<44 or data[:4]!=b'RIFF' or data[8:12]!=b'WAVE' or integer(4,4)!=len(data)-8: raise ValueError('invalid PCM RIFF')
    at=12;format_seen=False;frames=None
    while at<len(data):
        if len(data)-at<8: raise ValueError('truncated PCM chunk')
        count=integer(at+4,4);start=at+8
        if count>len(data)-start: raise ValueError('invalid PCM chunk length')
        if data[at:at+4]==b'fmt ':
            if format_seen or count!=16 or data[start:start+16] != b'\x01\x00\x01\x00\x00}\x00\x00\x00\xfa\x00\x00\x02\x00\x10\x00': raise ValueError('invalid PCM format')
            format_seen=True
        elif data[at:at+4]==b'data':
            if frames is not None or not count or count%2: raise ValueError('invalid PCM data')
            frames=count//2
        at=start+count+count%2
        if at>len(data): raise ValueError('missing PCM padding')
    if not format_seen or frames is None or not 96000<=frames<=320000: raise ValueError('invalid PCM duration')

def _zip_record(archive, entry, maximum, *, collect=False):
    if entry.flag_bits & 1 or entry.compress_type not in (zipfile.ZIP_STORED,zipfile.ZIP_DEFLATED) or not 0<entry.file_size<=maximum:
        raise ValueError('unsupported or oversized ZIP entry')
    mode = entry.external_attr >> 16
    if stat.S_IFMT(mode) not in (0,stat.S_IFREG): raise ValueError('ZIP special file or link')
    h=hashlib.sha256(); size=0; data=bytearray()
    with archive.open(entry) as f:
        for b in iter(lambda:f.read(CHUNK), b''):
            size+=len(b)
            if size>maximum or size>entry.file_size: raise ValueError('expanded ZIP size limit')
            h.update(b)
            if collect: data.extend(b)
    if size!=entry.file_size: raise ValueError('truncated ZIP entry')
    return size,h.hexdigest(),bytes(data)

def verify_voice_zip(path):
    prefix='胡桃-试用-e1/'
    expected={prefix+'voice.json',prefix+'s2.pth',prefix+'reference.wav','来源与许可.md'}
    try:
        with checked_reader(path) as (f, info), zipfile.ZipFile(f) as z:
            rows=z.infolist()
            if len(rows)!=4 or {i.filename for i in rows}!=expected: raise ValueError('unsafe or unexpected ZIP inventory')
            _,_,raw=_zip_record(z,z.getinfo(prefix+'voice.json'),16384,collect=True)
            manifest=_voice_manifest(raw)
            for key,name,maximum in [('model','s2.pth',268435456),('reference','reference.wav',1048576)]:
                size,digest,data=_zip_record(z,z.getinfo(prefix+name),maximum,collect=key=='reference')
                if size!=manifest[key]['bytes'] or digest!=manifest[key]['sha256']: raise ValueError('ZIP voice digest mismatch')
                if key=='reference': _pcm(data)
            _zip_record(z,z.getinfo('来源与许可.md'),65536)
    except (zipfile.BadZipFile,RuntimeError,OSError) as error: raise ValueError('invalid voice ZIP') from error
    return manifest,hashlib.sha256(raw).hexdigest()

def build_voice_zip(source, output, *, notices):
    source,output=Path(source),Path(output); _directory(source)
    if os.path.lexists(output): raise ValueError('ZIP output exists')
    if {p.name for p in source.iterdir()} != {'voice.json','s2.pth','reference.wav'}: raise ValueError('voice folder requires exactly three files')
    raw=_read(source/'voice.json',16384);m=_voice_manifest(raw)
    for key in ['model','reference']:
        a=snapshot_asset(source/m[key]['file'])
        if a.bytes!=m[key]['bytes'] or a.sha256!=m[key]['sha256']: raise ValueError('voice source digest mismatch')
    _pcm(_read(source/'reference.wav',1048576)); notice=_read(notices,65536)
    output.parent.mkdir(parents=True,exist_ok=True)
    owned=None
    try:
        with zipfile.ZipFile(output,'x',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as z:
            created=os.fstat(z.fp.fileno());owned=(created.st_dev,created.st_ino)
            for name in ['voice.json','s2.pth','reference.wav']:
                entry=zipfile.ZipInfo('胡桃-试用-e1/'+name,(2026,1,1,0,0,0));entry.compress_type=zipfile.ZIP_DEFLATED
                entry.create_system=3;entry.external_attr=(stat.S_IFREG|0o644)<<16
                with checked_reader(source/name) as (f,s),z.open(entry,'w') as target:
                    shutil.copyfileobj(f,target,CHUNK)
            entry=zipfile.ZipInfo('来源与许可.md',(2026,1,1,0,0,0));entry.create_system=3;entry.external_attr=(stat.S_IFREG|0o644)<<16
            z.writestr(entry,notice)
        verify_voice_zip(output)
    except BaseException:
        if owned and output.exists():
            current=output.lstat()
            if (current.st_dev,current.st_ino)==owned: output.unlink()
        raise
    return output

def _commit_directory(stage, output):
    # Both supported build hosts are macOS. RENAME_EXCL prevents even an empty
    # concurrently-created destination from being replaced at the final boundary.
    if sys.platform=='darwin':
        libc=ctypes.CDLL(None,use_errno=True);rename=libc.renamex_np
        rename.argtypes=[ctypes.c_char_p,ctypes.c_char_p,ctypes.c_uint];rename.restype=ctypes.c_int
        if rename(os.fsencode(stage),os.fsencode(output),4): raise OSError(ctypes.get_errno(),'exclusive directory commit failed')
    else:
        # Packaging is a macOS developer operation, not part of the Linux draft job.
        raise ValueError('atomic voice packaging requires macOS')

def _copy_verified(source, destination):
    expected=snapshot_asset(source)
    with checked_reader(source) as (f,s),Path(destination).open('xb') as target: shutil.copyfileobj(f,target,CHUNK)
    actual=snapshot_asset(destination)
    if (expected.bytes,expected.sha256)!=(actual.bytes,actual.sha256): raise ValueError('source changed during copy')

def build_bundle(engine_dmg, voice_zip, output, *, tools_commit, app_commit, readme, provenance):
    output=Path(output)
    if os.path.lexists(output): raise ValueError('bundle output exists')
    if not _hex(tools_commit,40) or app_commit!=APP_COMMIT: raise ValueError('invalid source commits')
    voice,voice_sha=verify_voice_zip(voice_zip)
    if set(provenance)!={'engineManifestSHA256','enginePayloadFiles','enginePayloadBytes','sourceNotice'} or not _hex(provenance['engineManifestSHA256'],64) or not _integer(provenance['enginePayloadFiles'],1,100000) or not _integer(provenance['enginePayloadBytes'],0,12*1024**3) or not isinstance(provenance['sourceNotice'],str) or not provenance['sourceNotice'].strip():
        raise ValueError('invalid provenance')
    if '/Users/' in json.dumps(provenance) or len(provenance['sourceNotice'].encode())>16384: raise ValueError('private or oversized provenance')
    installation=_read(readme,65536)
    if not installation.strip(): raise ValueError('empty installation instructions')
    output.parent.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.voice-assets-',dir=output.parent) as temporary:
        stage=Path(temporary)/'bundle';stage.mkdir()
        records=[]
        for source,name in [(engine_dmg,ENGINE),(voice_zip,VOICE)]:
            _copy_verified(Path(source),stage/name);a=snapshot_asset(stage/name)
            records.append({'name':name,'bytes':a.bytes,'sha256':a.sha256})
            (stage/(name+'.sha256')).write_text(a.sha256+'  '+name+'\n',encoding='utf-8')
        (stage/'安装说明.md').write_bytes(installation)
        manifest=dict(schemaVersion=1,version='1.0.0',toolsCommit=tools_commit,
            app={'minimumVersion':'0.7.0','sourceCommit':app_commit},
            engine={'id':'gpt-sovits-macos-arm64','version':'1.0.0','profile':PROFILE,'architecture':'arm64','minimumOS':'14.0','upstreamCommit':UPSTREAM},
            voice={'id':voice['id'],'manifestSHA256':voice_sha},assets=records,provenance=provenance,
            installation={'bytes':len(installation),'sha256':hashlib.sha256(installation).hexdigest()})
        raw=(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n').encode()
        if len(raw)>65536: raise ValueError('bundle manifest size limit')
        (stage/'voice-assets.json').write_bytes(raw)
        read_bundle(stage,version='1.0.0',tools_commit=tools_commit)
        _commit_directory(stage,output)
    return read_bundle(output,version='1.0.0',tools_commit=tools_commit)

def read_bundle(folder, *, version, tools_commit):
    folder=Path(folder);_directory(folder)
    if {p.name for p in folder.iterdir()}!=FILES: raise ValueError('expected exactly six resource assets')
    records=tuple(snapshot_asset(folder/name) for name in sorted(FILES))
    by_name={a.name:a for a in records}
    m=decode_json(_read(folder/'voice-assets.json',65536),65536)
    if set(m)!={'schemaVersion','version','toolsCommit','app','engine','voice','assets','provenance','installation'} or type(m['schemaVersion']) is not int or m['schemaVersion']!=1 or m['version']!=version or version!='1.0.0' or not _hex(tools_commit,40) or m['toolsCommit']!=tools_commit:
        raise ValueError('bundle schema or source mismatch')
    if m['app']!={'minimumVersion':'0.7.0','sourceCommit':APP_COMMIT} or m['engine']!={'id':'gpt-sovits-macos-arm64','version':'1.0.0','profile':PROFILE,'architecture':'arm64','minimumOS':'14.0','upstreamCommit':UPSTREAM}:
        raise ValueError('incompatible resource metadata')
    expected=[{'name':n,'bytes':by_name[n].bytes,'sha256':by_name[n].sha256} for n in [ENGINE,VOICE]]
    if not isinstance(m['assets'],list) or any(not isinstance(a,dict) or type(a.get('bytes')) is not int for a in m['assets']) or m['assets']!=expected: raise ValueError('resource bytes or digest mismatch')
    for name in [ENGINE,VOICE]:
        if _read(folder/(name+'.sha256'),1024)!=(by_name[name].sha256+'  '+name+'\n').encode(): raise ValueError('checksum mismatch')
    installation=by_name['安装说明.md']
    if not isinstance(m['installation'],dict) or type(m['installation'].get('bytes')) is not int or m['installation']!={'bytes':installation.bytes,'sha256':installation.sha256}: raise ValueError('instructions changed')
    voice,voice_sha=verify_voice_zip(folder/VOICE)
    if m['voice']!={'id':'hutao-pilot-e1','manifestSHA256':voice_sha}: raise ValueError('voice identity mismatch')
    p=m['provenance']
    if not isinstance(p,dict) or set(p)!={'engineManifestSHA256','enginePayloadFiles','enginePayloadBytes','sourceNotice'} or not _hex(p['engineManifestSHA256'],64) or not _integer(p['enginePayloadFiles'],1,100000) or not _integer(p['enginePayloadBytes'],0,12*1024**3) or not isinstance(p['sourceNotice'],str) or not p['sourceNotice'].strip() or '/Users/' in json.dumps(p): raise ValueError('invalid provenance')
    return VoiceBundle(version,tools_commit,m,records)
