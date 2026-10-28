"""Build an optional local engine image; ordinary App packaging never calls it."""
import ast
import hashlib
import pickle
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile

from local_voice_macho import audit_macho_tree
from local_voice_runtime import verify_record

REPO = Path(__file__).resolve().parents[1]
ASSET_METADATA = REPO / "Resources/LocalVoice/engine-assets.json"
PROFILE = "gpt-sovits-v2proplus-cpu1"
COMMIT = "b4570b876f5c086819ba84e3215472733c6a7b70"


def digest(path):
    value = hashlib.sha256()
    with Path(path).open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def safe_path(root, relative):
    parts = relative.split("/")
    if not parts or any(p in ("", ".", "..") or "\\" in p for p in parts):
        raise ValueError("invalid package path")
    root = Path(root)
    current = root
    if root.is_symlink():
        raise ValueError("linked package root")
    for part in parts:
        current = current / part
        if current.is_symlink():
            raise ValueError("linked package file")
    return current


def _extract_source(archive, destination):
    # Reuse the bounded, no-link upstream-source extractor, without invoking prepare.
    import sys
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("portable_upstream_source", REPO / "tools/prepare-local-voice.py")
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    module.extract_source(archive, destination)


def write_engine_manifest(package: Path, metadata: dict) -> dict:
    package = Path(package); payload = package / "payload"
    package.chmod(0o755); payload.chmod(0o755)
    records, total = [], 0
    for path in sorted(payload.rglob("*")):
        if path.is_symlink():
            raise ValueError("linked engine payload")
        if path.is_dir():
            path.chmod(0o755)
            continue
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or path.suffix == ".pyc" or "__pycache__" in path.parts or path.name == "direct_url.json":
            raise ValueError("special file or generated cache in engine payload")
        if path.name == ".DS_Store":
            raise ValueError("Finder metadata must not enter engine output")
        relative = path.relative_to(payload).as_posix()
        if len(relative.split("/")) > 32 or info.st_size > 2 * 1024**3:
            raise ValueError("engine path or file exceeds limits")
        total += info.st_size
        executable = bool(info.st_mode & 0o111)
        path.chmod(0o755 if executable else 0o644)
        records.append(dict(path=relative, bytes=info.st_size, sha256=digest(path), executable=executable))
    if len(records) > 100000 or total > 12 * 1024**3:
        raise ValueError("engine payload exceeds limits")
    result = {k: metadata[k] for k in ("schemaVersion", "id", "version", "name", "architecture", "minimumOS", "pythonVersion", "profile", "sourceCommit")}
    result["files"] = records
    data = (json.dumps(result, ensure_ascii=False, indent=2) + "\n").encode()
    if len(data) > 16 * 1024 * 1024:
        raise ValueError("engine manifest exceeds limits")
    (package / "engine.json").write_bytes(data)
    (package / "engine.json").chmod(0o644)
    return result


def prepare_polyphonic_cache(source):
    # The pinned upstream archive ships an out-of-date MD5 marker. Its first
    # generation otherwise rewrites files covered by our immutable manifest.
    # Build the same ordered dictionary from literals, without importing ML,
    # evaluating source expressions, or trusting a pre-existing pickle.
    folder = Path(source) / "GPT_SoVITS/text/g2pw"
    values, hashes = {}, []
    for name in ("polyphonic.rep", "polyphonic-fix.rep"):
        path = safe_path(folder, name)
        data = path.read_bytes()
        hashes.append(hashlib.md5(data).hexdigest())
        for line in data.decode("utf-8").splitlines():
            key, value = line.split(":", 1)
            values[key.strip()] = ast.literal_eval(value.strip())
    safe_path(folder,"polyphonic.pickle").write_bytes(pickle.dumps(values,protocol=4))
    safe_path(folder,"polyphonic.md5").write_text("".join(hashes),encoding="utf-8")


def _collect_licenses(payload):
    licenses = payload / "licenses"; licenses.mkdir()
    for subtree in ("runtime", "source"):
        for path in sorted((payload / subtree).rglob("*")):
            if path.is_file() and path.name.lower().startswith(("license", "licence", "copying", "notice")):
                target = licenses / subtree / path.relative_to(payload / subtree)
                target.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(path, target)
    shutil.copyfile(REPO / "docs/local-voice-engine-model-notices.md", licenses / "MODEL_NOTICES.md")
    shutil.copyfile(REPO / "tools/local-voice-runtime-m4.json", licenses / "RUNTIME_PROVENANCE.json")
    (licenses / "THIRD_PARTY_NOTICES.md").write_text("# 独立语音引擎\n\nPython/依赖和上游源码许可保留在原目录，并汇集于runtime、source子目录。公共模型来源与尚未核实的checkpoint许可见MODEL_NOTICES.md；原声及角色S2不在本引擎包中。\n", encoding="utf-8")


def assemble_engine(runtime: Path, experiment: Path, output: Path, *, engine_id: str, version: str) -> dict:
    runtime, experiment, output = Path(runtime), Path(experiment), Path(output)
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,63}", engine_id) or not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
        raise ValueError("invalid engine identity")
    if output.exists() or output.is_symlink():
        raise ValueError("engine output already exists")
    assets = json.loads(ASSET_METADATA.read_text())
    if assets["profile"] != PROFILE or assets["sourceCommit"] != COMMIT:
        raise ValueError("unsupported common model profile")
    archive = safe_path(experiment, assets["sourceArchive"]["experimentPath"])
    verify_record(archive, assets["sourceArchive"])
    for row in assets["files"]:
        if not row["path"].startswith("source/"):
            raise ValueError("common assets must be source-relative")
        verify_record(safe_path(experiment, row["experimentPath"]), row)
    audit_macho_tree(runtime)
    output.mkdir(parents=True)
    payload = output / "payload"; payload.mkdir()
    shutil.copytree(runtime, payload / "runtime", symlinks=True)
    _extract_source(archive, payload / "source")
    public_files = []
    for row in assets["files"]:
        target = safe_path(payload, row["path"])
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(safe_path(experiment, row["experimentPath"]), target)
        verify_record(target, row)
        public_files.append({k: row[k] for k in ("path", "bytes", "sha256")})
    clean_assets = dict(schemaVersion=1, profile=PROFILE, sourceCommit=COMMIT, files=public_files)
    (payload / "engine-assets.json").write_text(json.dumps(clean_assets, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    prepare_polyphonic_cache(payload / "source")
    _collect_licenses(payload)
    # Archive/installer tools may leave empty directories; packages list all real content.
    for path in sorted(payload.rglob("*"), reverse=True):
        if path.is_dir() and not path.is_symlink() and not any(path.iterdir()):
            path.rmdir()
    lock = json.loads((REPO / "tools/local-voice-runtime-m4.json").read_text())
    metadata = dict(schemaVersion=1, id=engine_id, version=version, name="本地中文语音引擎", architecture="arm64", minimumOS="14.0", pythonVersion=lock["pythonVersion"], profile=PROFILE, sourceCommit=COMMIT)
    return write_engine_manifest(output, metadata)


def package_engine_dmg(package: Path, output: Path, *, runner=subprocess.run) -> Path:
    package, output = Path(package), Path(output)
    if output.exists() or Path(str(output) + ".sha256").exists():
        raise ValueError("engine image output already exists")
    metadata = json.loads((package / "engine.json").read_text())
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".engine-image-", dir=output.parent) as temporary:
        work = Path(temporary); stage = work / "stage"; stage.mkdir()
        shutil.copytree(package, stage / package.name, symlinks=True)
        (stage / "安装说明.txt").write_text("先安装YeShunguangPet App。在完整聊天窗的语音页点击“安装或修复本地引擎…”，选择本卷内的引擎文件夹，核对后确认安装。安装完成即可弹出本卷。角色音色包需要另行导入、绑定和启用。\n", encoding="utf-8")
        image = work / "engine.dmg"
        runner(["/usr/bin/hdiutil", "create", "-volname", "角色语音引擎 " + metadata["version"], "-srcfolder", str(stage), "-format", "UDZO", "-ov", str(image)], check=True)
        runner(["/usr/bin/hdiutil", "verify", str(image)], check=True)
        image.rename(output)
    Path(str(output) + ".sha256").write_text(digest(output) + "  " + output.name + "\n", encoding="utf-8")
    return output
