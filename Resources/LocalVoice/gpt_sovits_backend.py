"""Fixed trusted GPT-SoVITS v2ProPlus CPU adapter; imported lazily by worker."""
import json
import os
from pathlib import Path
import socket
import sys

from voice_assets import safe_file, verify_assets, verify_file


def install_network_guard():
    """Defense against libraries that ignore offline flags, not an OS sandbox."""
    originals = []
    def blocked(*args, **kwargs):
        raise OSError("local voice network disabled")
    def connect(connection, *args, **kwargs):
        if connection.family in (socket.AF_INET, socket.AF_INET6):
            return blocked()
        return old_connect(connection, *args, **kwargs)
    old_connect = socket.socket.connect
    for owner, key, value in ((socket, "getaddrinfo", blocked), (socket, "gethostbyname", blocked), (socket, "gethostbyname_ex", blocked),
                              (socket, "create_connection", blocked), (socket.socket, "connect", connect), (socket.socket, "connect_ex", blocked)):
        originals.append((owner, key, getattr(owner, key)))
        setattr(owner, key, value)
    def undo():
        for owner, key, value in originals:
            setattr(owner, key, value)
    return undo


def validate_samples(rate, frames):
    if rate != 32000 or not 0 < frames <= 32000 * 240 or frames * 2 + 44 > 33554432:
        raise ValueError("empty or oversized generated audio")


class GPTSoVITSBackend:
    def __init__(self, engine_root: Path, voice_root: Path, work_root: Path):
        self.engine_root = Path(engine_root)
        self.voice_root = Path(voice_root)
        self.work_root = Path(work_root)
        self.source_root = self.engine_root / "source"
        self.config_path = self.work_root / "inference.yaml"
        self.model = None
        self.manifest = None

    def configuration(self):
        pretrained = self.source_root / "GPT_SoVITS/pretrained_models"
        return {"custom": {"version": "v2ProPlus", "device": "cpu", "is_half": False,
                           "t2s_weights_path": str(pretrained / "s1v3.ckpt"), "vits_weights_path": str(self.voice_root / "s2.pth"),
                           "bert_base_path": str(pretrained / "chinese-roberta-wwm-ext-large"),
                           "cnhuhbert_base_path": str(pretrained / "chinese-hubert-base")}}

    def inputs(self, text, speed_factor):
        return {"text": text, "text_lang": "all_zh", "ref_audio_path": str(self.voice_root / "reference.wav"),
                "prompt_text": self.manifest["promptText"] if self.manifest else "", "prompt_lang": "all_zh",
                "text_split_method": "cut0", "seed": 20261026, "batch_size": 1, "parallel_infer": False,
                "streaming_mode": False, "use_cuda_graph": False, "use_flash_attention": False, "speed_factor": speed_factor}

    def initialize(self):
        if sys.version_info[:2] != (3, 12):
            raise RuntimeError("Python 3.12 required")
        for directory in (self.engine_root, self.source_root, self.voice_root, self.work_root):
            if not directory.is_dir() or directory.is_symlink():
                raise ValueError("invalid runtime directory")
        assets_path = safe_file(self.engine_root, "engine-assets.json")
        assets = json.loads(assets_path.read_text())
        if assets["profile"] != "gpt-sovits-v2proplus-cpu1" or assets["sourceCommit"] != "b4570b876f5c086819ba84e3215472733c6a7b70":
            raise ValueError("unsupported engine")
        verify_assets(self.engine_root, assets)
        manifest_path = safe_file(self.voice_root, "voice.json")
        if manifest_path.stat().st_size > 16384:
            raise ValueError("oversized voice manifest")
        self.manifest = json.loads(manifest_path.read_text())
        if self.manifest["engineProfile"] != assets["profile"] or self.manifest["language"] != "zh-CN":
            raise ValueError("unsupported voice")
        for key, filename in (("model", "s2.pth"), ("reference", "reference.wav")):
            if self.manifest[key]["file"] != filename:
                raise ValueError("unexpected voice file")
            verify_file(safe_file(self.voice_root, filename), self.manifest[key])
        cache = self.engine_root.parents[2] / "Cache"
        for name in ("huggingface", "matplotlib", "numba", "nltk"):
            (cache / name).mkdir(parents=True, exist_ok=True, mode=0o700)
        os.environ.update({"HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1",
                           "GRADIO_ANALYTICS_ENABLED": "False", "OMP_NUM_THREADS": "4", "MKL_NUM_THREADS": "4",
                           "TOKENIZERS_PARALLELISM": "false", "language": "zh_CN", "HF_HOME": str(cache / "huggingface"),
                           "XDG_CACHE_HOME": str(cache), "MPLCONFIGDIR": str(cache / "matplotlib"),
                           "NUMBA_CACHE_DIR": str(cache / "numba"), "NLTK_DATA": str(cache / "nltk")})
        install_network_guard()
        os.chdir(self.source_root)
        sys.path[:0] = [str(self.source_root), str(self.source_root / "GPT_SoVITS")]
        import nltk
        nltk.data.path = [str(cache / "nltk")]
        def no_download(*args, **kwargs):
            raise RuntimeError("offline language resource unavailable")
        nltk.download = no_download
        import onnxruntime
        onnxruntime.disable_telemetry_events()
        import torch
        torch.set_num_threads(4)
        torch.set_num_interop_threads(1)
        from TTS_infer_pack.TTS import TTS, TTS_Config
        configuration = TTS_Config(self.configuration())
        configuration.configs_path = str(self.config_path)
        self.model = TTS(configuration)

    def generate(self, text, speed_factor, output):
        import numpy as np
        import soundfile as sf
        if self.model is None or output.parent != self.work_root or output.exists() or output.is_symlink():
            raise ValueError("invalid generation destination")
        chunks, frames = [], 0
        for rate, audio in self.model.run(self.inputs(text, speed_factor)):
            if getattr(audio, "ndim", None) != 1:
                raise ValueError("invalid channels")
            frames += len(audio)
            validate_samples(rate, frames)
            chunks.append(audio)
        validate_samples(32000, frames)
        temporary = output.with_suffix(".partial")
        try:
            # The parent owns a private task directory. Never overwrite an old path.
            fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, "wb") as target:
                sf.write(target, np.concatenate(chunks), 32000, format="WAV", subtype="PCM_16")
            if temporary.stat().st_size > 33554432:
                raise ValueError("oversized WAV")
            os.replace(temporary, output)
        finally:
            temporary.unlink(missing_ok=True)
        return {"sampleRate": 32000, "frames": frames}
