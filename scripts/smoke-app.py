#!/usr/bin/env python3
"""Launch only our packaged app, detect early exit, and stop that exact test PID."""
from pathlib import Path
import os, subprocess, tempfile, time
root=Path(__file__).resolve().parents[1]
app=root/'dist/YeShunguangPet.app/Contents/MacOS/YeShunguangPet'
with tempfile.TemporaryDirectory(prefix='pet-smoke-') as tmp:
    log=Path(tmp)/'launch.log'
    env=dict(os.environ, YSGPET_SETTINGS_PATH=str(Path(tmp)/'settings.json'), YSGPET_METRICS_PATH=str(Path(tmp)/'metrics.json'))
    with log.open('wb') as stream:
        p=subprocess.Popen([str(app)],env=env,stdout=stream,stderr=subprocess.STDOUT,start_new_session=True)
        try:
            deadline=time.monotonic()+2
            while p.poll() is None and time.monotonic()<deadline: time.sleep(.05)
            if p.poll() is not None:
                print(log.read_text(errors='replace'))
                raise SystemExit(f'App exited early: {p.returncode}')
            print(f'Packaged app remained alive for 2 seconds (PID {p.pid}); pointer interaction not tested')
        finally:
            if p.poll() is None:
                p.terminate()
                try: p.wait(timeout=3)
                except subprocess.TimeoutExpired: p.kill(); p.wait()

    if p.returncode != 0:
        raise SystemExit(f'App did not exit gracefully: {p.returncode}')
    import json
    metrics=json.loads((Path(tmp)/'metrics.json').read_text())
    assert metrics['visible'] and metrics['frameUpdates'] > 0
    assert (Path(tmp)/'settings.json').is_file()
    print('Graceful exit, visible runtime, frame updates and isolated settings: passed')
