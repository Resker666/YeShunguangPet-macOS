"""App-owned, offline public-engine check. Never loads a character model."""
import argparse
import contextlib
import importlib
import json
import os
from pathlib import Path
import platform
import sys
import threading
import uuid

from gpt_sovits_backend import install_network_guard
from voice_assets import safe_file, verify_assets

PROFILE = 'gpt-sovits-v2proplus-cpu1'
COMMIT = 'b4570b876f5c086819ba84e3215472733c6a7b70'


def check_engine(engine, cache):
    if sys.version_info[:2] != (3, 12):
        raise RuntimeError('Python 3.12 required')
    if platform.machine() != 'arm64':
        raise RuntimeError('Apple Silicon required')
    engine, cache = Path(engine), Path(cache)
    source = engine / 'source'
    if not engine.is_dir() or engine.is_symlink() or not source.is_dir() or source.is_symlink():
        raise ValueError('engine source missing or linked')
    asset_path = safe_file(engine, 'engine-assets.json')
    if asset_path.stat().st_size > 65536:
        raise ValueError('oversized asset manifest')
    assets = json.loads(asset_path.read_text())
    if assets['profile'] != PROFILE or assets['sourceCommit'] != COMMIT:
        raise ValueError('unsupported engine profile')
    verify_assets(engine, assets)
    for name in ('huggingface', 'matplotlib', 'numba', 'nltk', 'temporary'):
        target = cache / name
        if target.is_symlink(): raise ValueError('linked cache directory')
        target.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.environ.update({'HF_HUB_OFFLINE':'1','TRANSFORMERS_OFFLINE':'1','HF_HUB_DISABLE_TELEMETRY':'1',
        'GRADIO_ANALYTICS_ENABLED':'False','TOKENIZERS_PARALLELISM':'false','language':'zh_CN',
        'HF_HOME':str(cache/'huggingface'),'XDG_CACHE_HOME':str(cache),'MPLCONFIGDIR':str(cache/'matplotlib'),
        'NUMBA_CACHE_DIR':str(cache/'numba'),'NLTK_DATA':str(cache/'nltk'),'TMPDIR':str(cache/'temporary'),
        'OMP_NUM_THREADS':'4','MKL_NUM_THREADS':'4','TORIO_USE_FFMPEG':'0','TORCHAUDIO_USE_SOX':'0'})
    undo = install_network_guard()
    old_path, old_cwd = sys.path[:], os.getcwd()
    try:
        sys.path[:0] = [str(source),str(source/'GPT_SoVITS')]
        # Upstream SV resolves imports from its source cwd. All writable caches
        # stay outside source; no TTS instance/config writer is constructed.
        os.chdir(source)
        nltk = importlib.import_module('nltk'); nltk.data.path = [str(cache/'nltk')]
        def no_download(*args, **kwargs): raise RuntimeError('offline language resource unavailable')
        nltk.download = no_download
        ort = importlib.import_module('onnxruntime'); ort.disable_telemetry_events()
        torch = importlib.import_module('torch'); torch.set_num_threads(4); torch.set_num_interop_threads(1)
        for name in ('torchaudio','transformers','librosa','peft','pytorch_lightning','torchmetrics','resampy','soundfile','TTS_infer_pack.TTS'):
            importlib.import_module(name)
    finally:
        sys.path[:] = old_path; os.chdir(old_cwd); undo()
    return dict(pythonVersion='.'.join(map(str,sys.version_info[:3])),profile=PROFILE,sourceCommit=COMMIT)


def watch_parent():
    # EOF also kills blocked native imports after the parent exits. No commands.
    os.read(0, 1)
    os._exit(2)


def main(argv=None):
    p = argparse.ArgumentParser()
    for name in ('engine-root','cache-root','request-id'):p.add_argument('--'+name,required=True)
    args = p.parse_args(argv); request = str(uuid.UUID(args.request_id))
    threading.Thread(target=watch_parent,daemon=True).start()
    try:
        with contextlib.redirect_stdout(sys.stderr):
            report = check_engine(Path(args.engine_root),Path(args.cache_root))
    except ImportError as failure:
        print('dependency: required engine library unavailable: ' + str(failure.name or 'import'),file=sys.stderr);return 3
    except (ValueError,KeyError,OSError):
        print('resource: public engine assets unavailable or invalid',file=sys.stderr);return 4
    except RuntimeError:
        print('runtime: incompatible Python, architecture or offline resource',file=sys.stderr);return 5
    print(json.dumps(dict(v=1,event='checked',requestID=request,**report)),flush=True)
    return 0

if __name__ == '__main__':raise SystemExit(main())
