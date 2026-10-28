"""Explicit developer-side construction; never called by the App installer."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tarfile
import urllib.request


def verify_record(path, record):
    info = Path(path).lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_size != record["bytes"]:
        raise ValueError("download size mismatch: " + Path(path).name)
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    if digest.hexdigest() != record["sha256"]:
        raise ValueError("download digest mismatch: " + Path(path).name)


def download_locked(record, directory):
    filename = record["file"]
    if Path(filename).name != filename or not record["url"].startswith("https://"):
        raise ValueError("invalid download record")
    directory = Path(directory); directory.mkdir(parents=True, exist_ok=True)
    target = directory / filename
    if not target.exists():
        temporary = target.with_name(target.name + ".partial")
        try:
            with urllib.request.urlopen(record["url"], timeout=30) as source, temporary.open("xb") as output:
                total = 0
                while chunk := source.read(1024 * 1024):
                    total += len(chunk)
                    if total > record["bytes"]:
                        raise ValueError("download exceeds locked size")
                    output.write(chunk)
            verify_record(temporary, record)
            temporary.rename(target)
        finally:
            temporary.unlink(missing_ok=True)
    verify_record(target, record)
    return target


def materialize_symlinks(root):
    root = Path(root).resolve(strict=True)
    links = []
    for path in root.rglob("*"):
        if not path.is_symlink():
            continue
        try:
            resolved = path.resolve(strict=True)
        except (OSError, RuntimeError) as error:
            raise ValueError("invalid runtime link") from error
        if not resolved.is_relative_to(root):
            raise ValueError("runtime link leaves payload")
        links.append((path, resolved))
    # Resolve all targets first; a later alias may name a link removed earlier.
    for path, resolved in links:
        path.unlink()
        if resolved.is_dir():
            shutil.copytree(resolved, path)
        elif resolved.is_file():
            shutil.copy2(resolved, path)
        else:
            raise ValueError("unsupported link target")


def extract_python(archive, destination):
    destination = Path(destination); destination.mkdir(parents=True, exist_ok=False)
    links = []
    with tarfile.open(archive, "r:gz") as bundle:
        members = bundle.getmembers()
        if len(members) > 100000:
            raise ValueError("oversized Python archive")
        total = 0
        for item in members:
            parts = Path(item.name).parts
            if not parts or parts[0] != "python" or ".." in parts or Path(item.name).is_absolute():
                raise ValueError("unexpected Python archive path")
            if len(parts) == 1:
                continue
            target = destination.joinpath(*parts[1:])
            if item.isdir():
                target.mkdir(parents=True, exist_ok=True)
            elif item.isfile():
                total += item.size
                if not 0 <= item.size <= 256 * 1024 * 1024 or total > 2 * 1024**3:
                    raise ValueError("oversized Python archive member")
                target.parent.mkdir(parents=True, exist_ok=True)
                with bundle.extractfile(item) as source, target.open("xb") as output:
                    shutil.copyfileobj(source, output, 65536)
                target.chmod(0o755 if item.mode & 0o111 else 0o644)
            elif item.issym():
                links.append((target, item.linkname))
            else:
                raise ValueError("unsupported Python archive member")
    for target, link in links:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.symlink_to(link)
    materialize_symlinks(destination)


def build_environment(build_root):
    environment = dict(os.environ)
    for name in ("PYTHONPATH", "PYTHONHOME"):
        environment.pop(name, None)
    environment.update({"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "MACOSX_DEPLOYMENT_TARGET": "14.0",
                        "PYTHONDONTWRITEBYTECODE": "1", "PYTHONNOUSERSITE": "1", "PIP_CONFIG_FILE": "/dev/null",
                        "PIP_DISABLE_PIP_VERSION_CHECK": "1", "PIP_CACHE_DIR": str(Path(build_root).resolve() / "pip-cache"),
                        "SOURCE_DATE_EPOCH": "315532800", "LDFLAGS": "", "CFLAGS": "-g0", "CXXFLAGS": "-g0"})
    return environment


def build_source_wheels(python, sources, build_root, *, runner=subprocess.run):
    build_root = Path(build_root)
    archives = [download_locked(row, build_root / "sources") for row in sources]
    destination = build_root / "built-wheels"
    destination.mkdir(parents=True, exist_ok=True)
    for archive in archives:
        runner([str(python), "-m", "pip", "wheel", "--no-index", "--no-cache-dir", "--no-deps", "--no-build-isolation",
                "--wheel-dir", str(destination), str(archive)], env=build_environment(build_root), check=True)
    records = []
    for path in sorted(destination.glob("*.whl")):
        records.append({"file": path.name, "bytes": path.stat().st_size, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
    if len(records) != len(sources):
        raise ValueError("source build did not produce exactly one wheel per package")
    return records


def finalize_runtime(runtime, *, exclude=()):
    runtime = Path(runtime).resolve(strict=True)
    selected = []
    for relative in exclude:
        path = (runtime / relative).resolve(strict=True)
        if Path(relative).is_absolute() or not path.is_relative_to(runtime) or not path.is_file():
            raise ValueError("invalid optional backend removal")
        selected.append(path)
    for path in selected:
        path.unlink()
    # Console entry scripts are not used; retain only actual interpreter names.
    for path in (Path(runtime) / "bin").iterdir():
        if path.is_file() and path.name not in ("python", "python3", "python3.12"):
            path.unlink()
    for path in Path(runtime).rglob("*.pyc"):
        path.unlink()
    for path in Path(runtime).rglob("*.dist-info/direct_url.json"):
        path.unlink()
    for path in sorted(Path(runtime).rglob("__pycache__"), reverse=True):
        if path.is_dir() and not any(path.iterdir()):
            path.rmdir()
    materialize_symlinks(runtime)


def apply_relocations(runtime, relocations, *, runner=subprocess.run):
    runtime = Path(runtime).resolve(strict=True)
    validated = []
    for row in relocations:
        target = (runtime / row["file"]).resolve(strict=True)
        rpath = row["addRPath"]
        if not target.is_relative_to(runtime) or not rpath.startswith("@loader_path/") or Path(row["library"]).name != row["library"]:
            raise ValueError("invalid runtime relocation")
        library = (target.parent / rpath[len("@loader_path/"):] / row["library"]).resolve(strict=True)
        if not library.is_relative_to(runtime) or not library.is_file():
            raise ValueError("relocation leaves runtime")
        validated.append((target, rpath))
    for target, rpath in validated:
        runner(["/usr/bin/install_name_tool", "-add_rpath", rpath, str(target)], check=True)
        runner(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", str(target)], check=True)


def prepare_runtime(build_root: Path, lock: dict, *, runner=subprocess.run) -> Path:
    build_root = Path(build_root)
    archive = download_locked(lock["python"], build_root / "downloads")
    wheels = [download_locked(row, build_root / "wheels") for row in lock["wheels"]]
    runtime = build_root / "runtime"
    extract_python(archive, runtime)
    python = runtime / "bin/python3.12"
    sources = lock.get("sources", [])
    if sources:
        setuptools = [path for path in wheels if path.name.startswith("setuptools-")]
        if len(setuptools) != 1 or len(lock.get("builtWheels", [])) != len(sources):
            raise ValueError("source wheels must be explicitly built and pinned before runtime assembly")
        runner([str(python), "-m", "pip", "install", "--no-compile", "--no-index", "--no-deps", str(setuptools[0])], env=build_environment(build_root), check=True)
        destination = build_root / "built-wheels"
        if not all((destination / row["file"]).is_file() for row in lock["builtWheels"]):
            build_source_wheels(python, sources, build_root, runner=runner)
        for row in lock["builtWheels"]:
            path = destination / row["file"]
            verify_record(path, row)
            wheels.append(path)
    if wheels:
        runner([str(python), "-m", "pip", "install", "--no-compile", "--no-index", "--no-deps", *map(str, wheels)], env=build_environment(build_root), check=True)
    finalize_runtime(runtime, exclude=lock.get("excludedOptionalBackends", []))
    apply_relocations(runtime, lock.get("relocations", []), runner=runner)
    return runtime


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--lock", type=Path, required=True)
    parser.add_argument("--build-root", type=Path, required=True)
    args = parser.parse_args()
    print(prepare_runtime(args.build_root, json.loads(args.lock.read_text())))
