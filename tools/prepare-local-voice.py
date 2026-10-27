#!/usr/bin/env python3
"""Explicit current-M4 preparation. The App never invokes this installer."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile
import uuid
import wave

REPO = Path(__file__).resolve().parents[1]
RESOURCES = REPO / "Resources/LocalVoice"
sys.path.insert(0, str(RESOURCES))
from voice_assets import safe_file, verify_assets, verify_file

PROFILE = "gpt-sovits-v2proplus-cpu1"
COMMIT = "b4570b876f5c086819ba84e3215472733c6a7b70"


def metadata():
    return json.loads((RESOURCES / "engine-assets.json").read_text())


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = path.parent / (".prepare-" + str(uuid.uuid4()))
    try:
        with temporary.open("x", encoding="utf-8") as target:
            os.chmod(temporary, 0o600)
            json.dump(value, target, ensure_ascii=False, indent=2)
            target.write("\n")
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def ensure_inactive(data_root):
    """Inspect executable paths only, never command arguments or process environments."""
    local = (data_root / "LocalVoice/Engine/Versions").resolve()
    personal = Path.home() / "Library/Application Support/YeShunguangPet-macOS"
    result = subprocess.run(["/bin/ps", "-axo", "pid=,comm="], check=True, text=True, capture_output=True)
    for line in result.stdout.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) != 2:
            continue
        executable = fields[1]
        worker = executable.startswith(str(local) + "/")
        app = data_root.resolve() == personal.resolve() and executable in (
            "/Applications/YeShunguangPet.app/Contents/MacOS/YeShunguangPet",
            str(Path.home() / "Applications/YeShunguangPet.app/Contents/MacOS/YeShunguangPet"),
        )
        if worker or app:
            raise RuntimeError("请先正常退出目标 App 和本地语音引擎，再准备或切换环境。")


def extract_source(archive, destination):
    destination.mkdir(mode=0o700)
    with tarfile.open(archive, "r:gz") as source:
        members = source.getmembers()
        if len(members) > 10000:
            raise ValueError("unexpected source archive")
        for member in members:
            parts = Path(member.name).parts
            if not parts or parts[0].startswith("/") or ".." in parts:
                raise ValueError("unsafe source archive")
            if len(parts) == 1:
                continue
            target = destination.joinpath(*parts[1:])
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True, mode=0o700)
            elif member.isfile() and member.size <= 64 * 1024 * 1024:
                target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                with source.extractfile(member) as reader, target.open("xb") as writer:
                    shutil.copyfileobj(reader, writer, 65536)
                target.chmod(0o600)
            else:
                raise ValueError("linked or unsupported source archive entry")


def offline_environment(cache):
    environment = dict(os.environ)
    environment.update({"HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1",
                        "GRADIO_ANALYTICS_ENABLED": "False", "OMP_NUM_THREADS": "4", "MKL_NUM_THREADS": "4",
                        "TOKENIZERS_PARALLELISM": "false", "PYTHONDONTWRITEBYTECODE": "1", "language": "zh_CN",
                        "HF_HOME": str(cache / "huggingface"), "XDG_CACHE_HOME": str(cache),
                        "MPLCONFIGDIR": str(cache / "matplotlib"), "NUMBA_CACHE_DIR": str(cache / "numba")})
    return environment


def prepare(experiment, python, settings, *, manifest=None, runner=subprocess.run):
    experiment, settings, python = Path(experiment), Path(settings), Path(python)
    if platform.machine() != "arm64":
        raise RuntimeError("首版环境仅支持当前 Apple Silicon Mac")
    ensure_inactive(settings.parent)
    manifest = manifest or metadata()
    archive = safe_file(experiment, manifest["sourceArchive"]["experimentPath"])
    verify_file(archive, manifest["sourceArchive"])
    # Check the interpreter before making a version directory.
    result = runner([str(python), "-c", "import platform,sys; assert sys.version_info[:2]==(3,12); assert platform.machine()=='arm64'; print(platform.python_version())"], check=True, text=True, capture_output=True)
    if not result.stdout.strip().startswith("3.12."):
        raise RuntimeError("需要 arm64 Python 3.12")
    identifier = str(uuid.uuid4()).upper()
    engine = settings.parent / "LocalVoice/Engine"
    version = engine / "Versions" / identifier
    version.mkdir(parents=True, mode=0o700)
    extract_source(archive, version / "source")
    for record in manifest["files"]:
        source = safe_file(experiment, record["experimentPath"])
        verify_file(source, record)
        destination = safe_file(version, record["path"])
        destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        shutil.copyfile(source, destination)
        destination.chmod(0o600)
    verify_assets(version, manifest)
    atomic_json(version / "engine-assets.json", manifest)
    venv = version / "venv"
    runner([str(python), "-m", "venv", str(venv)], check=True)
    interpreter = venv / "bin/python"
    runner([str(interpreter), "-m", "pip", "install", "--disable-pip-version-check", "-r", str(REPO / "tools/local-voice-requirements-m4.txt")], check=True)
    cache = settings.parent / "LocalVoice/Cache"
    cache.mkdir(parents=True, exist_ok=True, mode=0o700)
    probe = "import sys;sys.path[:0]=[sys.argv[1],sys.argv[1]+'/GPT_SoVITS'];import torch,torchaudio,transformers,onnxruntime,librosa,peft,pytorch_lightning,torchmetrics,resampy,soundfile;from TTS_infer_pack.TTS import TTS,TTS_Config;print('inference imports ready')"
    runner([str(interpreter), "-c", probe, str(version / "source")], cwd=str(version / "source"), env=offline_environment(cache), check=True)
    descriptor = {"schemaVersion": 1, "versionID": identifier, "profile": PROFILE, "architecture": "arm64", "pythonVersion": "3.12", "sourceCommit": COMMIT,
                  "python": "venv/bin/python", "source": "source", "assets": "engine-assets.json"}
    ensure_inactive(settings.parent)
    atomic_json(engine / "current.json", descriptor)
    return descriptor


def check(settings):
    engine = Path(settings).parent / "LocalVoice/Engine"
    descriptor = json.loads((engine / "current.json").read_text())
    identifier = str(uuid.UUID(descriptor["versionID"])).upper()
    if (descriptor["schemaVersion"] != 1 or descriptor["profile"] != PROFILE or descriptor["sourceCommit"] != COMMIT or
        descriptor["architecture"] != "arm64" or descriptor["pythonVersion"] != "3.12" or descriptor["python"] != "venv/bin/python" or descriptor["source"] != "source" or descriptor["assets"] != "engine-assets.json"):
        raise ValueError("unsupported engine descriptor")
    version = engine / "Versions" / identifier
    assets = json.loads(safe_file(version, "engine-assets.json").read_text())
    verify_assets(version, assets)
    return descriptor


def export_voice(experiment, candidate, output, *, manifest=None):
    if candidate != "e1":
        raise ValueError("首版仅导出已确认的 e1 候选")
    manifest = manifest or metadata()
    output, experiment = Path(output), Path(experiment)
    voice = manifest["voice"]
    for key in ("model", "reference"):
        verify_file(safe_file(experiment, voice[key]["experimentPath"]), voice[key])
    reference = safe_file(experiment, voice["reference"]["experimentPath"])
    with wave.open(str(reference), "rb") as wav:
        if wav.getnchannels() != 1 or wav.getsampwidth() != 2 or wav.getframerate() != 32000 or not 3 <= wav.getnframes() / 32000 <= 10:
            raise ValueError("invalid reference WAV")
    output.mkdir(parents=True, mode=0o700, exist_ok=False)
    package = {"schemaVersion": 1, "id": "hutao-pilot-e1", "name": "胡桃 · 试用 e1", "language": "zh-CN", "engineProfile": PROFILE,
               "promptText": voice["promptText"], "suggestedCharacterID": "hutao"}
    for key, filename in (("model", "s2.pth"), ("reference", "reference.wav")):
        shutil.copyfile(safe_file(experiment, voice[key]["experimentPath"]), output / filename)
        (output / filename).chmod(0o600)
        package[key] = {"file": filename, "bytes": voice[key]["bytes"], "sha256": voice[key]["sha256"]}
    atomic_json(output / "voice.json", package)
    return package


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    install = commands.add_parser("prepare")
    install.add_argument("--experiment", type=Path, required=True)
    install.add_argument("--python", type=Path, required=True)
    install.add_argument("--settings-path", type=Path, required=True)
    export = commands.add_parser("export-voice")
    export.add_argument("--experiment", type=Path, required=True)
    export.add_argument("--candidate", choices=["e1"], required=True)
    export.add_argument("--output", type=Path, required=True)
    validate = commands.add_parser("check")
    validate.add_argument("--settings-path", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "prepare":
        value = prepare(args.experiment.resolve(), args.python.absolute(), args.settings_path.absolute())
    elif args.command == "export-voice":
        value = export_voice(args.experiment.resolve(), args.candidate, args.output.absolute())
    else:
        value = check(args.settings_path.absolute())
    print(json.dumps(value, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
