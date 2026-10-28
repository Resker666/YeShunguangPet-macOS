#!/usr/bin/env python3
"""Explicit offline-engine artifact build, independent of ordinary App CI."""
import argparse
from pathlib import Path
import sys

sys.dont_write_bytecode = True
from local_voice_package import assemble_engine, package_engine_dmg

parser = argparse.ArgumentParser()
parser.add_argument("--runtime", type=Path, required=True)
parser.add_argument("--experiment", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--version", required=True)
parser.add_argument("--id", default="gpt-sovits-macos-arm64")
parser.add_argument("--dmg", type=Path)
args = parser.parse_args()
result = assemble_engine(args.runtime, args.experiment, args.output, engine_id=args.id, version=args.version)
print("Engine:", result["id"], result["version"], "files:", len(result["files"]), "bytes:", sum(r["bytes"] for r in result["files"]), flush=True)
if args.dmg:
    print(package_engine_dmg(args.output, args.dmg), flush=True)
