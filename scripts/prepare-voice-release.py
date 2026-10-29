#!/usr/bin/env python3
"""Check optional voice assets offline, or explicitly prepare/publish their prerelease."""
import argparse
import json
import os
from pathlib import Path
import sys
import time

sys.dont_write_bytecode=True
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from voice_distribution import read_bundle, _read
from voice_release import REPOSITORY,TAG,VoiceGitHub,VoiceAPIError,prepare_voice_release,publish_voice_release,verify_public_downloads

def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--assets',type=Path,required=True);parser.add_argument('--version',required=True);parser.add_argument('--commit',required=True)
    parser.add_argument('--notes',type=Path);parser.add_argument('--download-to',type=Path)
    mode=parser.add_mutually_exclusive_group()
    mode.add_argument('--check-only',action='store_true');mode.add_argument('--prepare-draft',action='store_true');mode.add_argument('--publish',action='store_true')
    args=parser.parse_args(argv)
    bundle=read_bundle(args.assets,version=args.version,tools_commit=args.commit)
    if args.download_to and not args.publish:raise ValueError('--download-to requires explicit --publish')
    if not args.prepare_draft and not args.publish:
        print(json.dumps({'commit':bundle.tools_commit,'version':bundle.version,'checkOnly':True,
                         'assets':[{'name':a.name,'bytes':a.bytes,'sha256':a.sha256} for a in bundle.assets]},ensure_ascii=False));return
    if args.notes is None:raise ValueError('explicit release operation requires prepared notes')
    notes=_read(args.notes,65536).decode('utf-8')
    token=os.environ.get('GH_TOKEN') or os.environ.get('GITHUB_TOKEN')
    last=[0.0]
    def progress(sent,total):
        now=time.monotonic()
        if sent==total or now-last[0]>=10:
            print('语音资源上传：'+str(sent)+' / '+str(total)+' 字节',file=sys.stderr,flush=True);last[0]=now
    api=VoiceGitHub(REPOSITORY,token,progress=progress)
    result=(publish_voice_release if args.publish else prepare_voice_release)(api,bundle,notes)
    summary={'commit':bundle.tools_commit,'tag':TAG,'draft':result['draft'],'prerelease':result['prerelease'],
             'releaseID':result['id'],'url':'https://github.com/'+REPOSITORY+'/releases/tag/'+TAG,'verifiedAttachments':len(result['assets'])}
    if args.download_to:summary['downloadVerification']=verify_public_downloads(bundle,result,args.download_to)
    print(json.dumps(summary,ensure_ascii=False))

if __name__=='__main__':
    try:main()
    except (OSError,ValueError,VoiceAPIError) as error:raise SystemExit('Voice release failed: '+str(error))
