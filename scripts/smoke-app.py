#!/usr/bin/env python3
"""Run an explicit bundle with isolated settings and no developer environment."""
from pathlib import Path
import argparse
import json
import os
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def run_once(binary, work, sequence):
    log = work / ("launch-%s.log" % sequence)
    metrics_path = work / ("metrics-%s.json" % sequence)
    settings = work / "settings.json"
    # No inherited DYLD/Xcode variables: XCTest must not mask missing libraries.
    env = {name: os.environ[name] for name in ["HOME", "USER", "TMPDIR", "LANG"] if name in os.environ}
    env.update(PATH="/usr/bin:/bin", DEVELOPER_DIR="/nonexistent-ysg-developer-tools",
               YSGPET_SETTINGS_PATH=str(settings), YSGPET_METRICS_PATH=str(metrics_path))
    with log.open("wb") as stream:
        process = subprocess.Popen([str(binary)], cwd=work, env=env, stdout=stream,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            deadline = time.monotonic() + 15
            while process.poll() is None and time.monotonic() < deadline:
                if "YSGPET: runtime ready" in log.read_text(errors="replace"):
                    break
                time.sleep(.05)
            if process.poll() is not None or "YSGPET: runtime ready" not in log.read_text(errors="replace"):
                raise RuntimeError("App did not become ready: %s\n%s" % (process.poll(), log.read_text(errors="replace")))
            deadline = time.monotonic() + 2
            while process.poll() is None and time.monotonic() < deadline:
                time.sleep(.05)
            if process.poll() is not None:
                raise RuntimeError("App exited early: %s" % process.returncode)
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
    if process.returncode != 0:
        raise RuntimeError("App did not exit gracefully: %s" % process.returncode)
    metrics = json.loads(metrics_path.read_text())
    if not metrics["visible"] or metrics["frameUpdates"] <= 0 or not settings.is_file():
        raise RuntimeError("Visible runtime, animation or settings missing")
    return metrics


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=ROOT / "dist/YeShunguangPet.app")
    parser.add_argument("--check-restore", action="store_true")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    binary = args.app.resolve() / "Contents/MacOS/YeShunguangPet"
    if not binary.is_file():
        parser.error("App executable missing: " + str(binary))
    with tempfile.TemporaryDirectory(prefix="ysg launch 中文 ") as temporary:
        work = Path(temporary)
        result = {"app": str(args.app.resolve()), "firstRun": run_once(binary, work, 1), "restored": False}
        if args.check_restore:
            settings = work / "settings.json"
            config = json.loads(settings.read_text())
            saved = config["placement"]
            for axis, length, size in [("x", "Width", "width"), ("y", "Height", "height")]:
                minimum = saved["visible" + axis.upper()]
                saved[axis] = minimum + min(48, max(0, saved["visible" + length] - result["firstRun"]["window"][size]))
            settings.write_text(json.dumps(config))
            result["secondRun"] = run_once(binary, work, 2)
            actual = json.loads(settings.read_text())["placement"]
            if any(abs(actual[axis] - saved[axis]) > .01 for axis in ["x", "y"]):
                raise RuntimeError("Saved placement was not restored: " + json.dumps(actual))
            result["restored"] = True
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    print("Visible animation, isolated settings and graceful exit: passed; pointer interaction not tested")


if __name__ == "__main__":
    main()
