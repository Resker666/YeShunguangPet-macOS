#!/usr/bin/env python3
"""Explicit developer packaging of an already verified, independent voice image."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile

sys.dont_write_bytecode=True
from voice_distribution import APP_COMMIT, MANIFEST_SHA, build_bundle, build_voice_zip, verify_engine_tree

def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ['engine-dmg','engine-package','voice','output','readme','notices']: p.add_argument('--'+name,type=Path,required=True)
    p.add_argument('--commit',required=True);p.add_argument('--manifest-sha256',default=MANIFEST_SHA)
    args=p.parse_args()
    if args.output.exists() or args.output.is_symlink(): raise ValueError('output exists')
    checked=verify_engine_tree(args.engine_package,expected_manifest_sha256=args.manifest_sha256)
    with tempfile.TemporaryDirectory(prefix='voice-zip-') as temporary:
        archive=build_voice_zip(args.voice,Path(temporary)/'voice.zip',notices=args.notices)
        provenance={'engineManifestSHA256':checked['manifestSHA256'],'enginePayloadFiles':checked['files'],
                    'enginePayloadBytes':checked['payloadBytes'],'sourceNotice':args.notices.read_text(encoding='utf-8')}
        result=build_bundle(args.engine_dmg,archive,args.output,tools_commit=args.commit,app_commit=APP_COMMIT,readme=args.readme,provenance=provenance)
    print(json.dumps({'version':result.version,'commit':result.tools_commit,'assets':[{'name':a.name,'bytes':a.bytes,'sha256':a.sha256} for a in result.assets]},ensure_ascii=False))

if __name__=='__main__':
    try: main()
    except (OSError,ValueError) as error: raise SystemExit('Voice packaging failed: '+str(error))
