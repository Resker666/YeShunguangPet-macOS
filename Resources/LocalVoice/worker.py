#!/usr/bin/env python3
"""Private child process entry point. Paths and session only; no text in argv."""
import argparse
import os
from pathlib import Path
import sys

sys.dont_write_bytecode = True
from worker_protocol import serve
from voice_assets import acquire_engine_lock


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--engine-root", type=Path, required=True)
    parser.add_argument("--voice-root", type=Path, required=True)
    parser.add_argument("--work-root", type=Path, required=True)
    parser.add_argument("--session-id", required=True)
    args = parser.parse_args()
    # Retain a protocol-only handle before redirecting both Python and C stdout.
    protocol = os.fdopen(os.dup(1), "w", encoding="utf-8", buffering=1)
    discard = os.open(os.devnull, os.O_WRONLY)
    os.dup2(discard, 1)
    os.close(discard)
    class Factory:
        session_id = args.session_id
        def __call__(self):
            self.lock = acquire_engine_lock(args.engine_root.parents[1], exclusive=False)
            from gpt_sovits_backend import GPTSoVITSBackend
            return GPTSoVITSBackend(args.engine_root, args.voice_root, args.work_root)
    return serve(sys.stdin.buffer, protocol, Factory())


if __name__ == "__main__":
    # Framework initialization may still occupy a daemon thread after parent EOF.
    # There is no persistent child state to flush; the OS releases its resources.
    os._exit(main())
