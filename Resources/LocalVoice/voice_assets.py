"""Bounded, offline integrity checks shared by the explicit installer and worker."""
import hashlib
from pathlib import Path
import stat
import os
import fcntl


def acquire_engine_lock(engine, *, exclusive):
    """Hold the returned descriptor for the entire installer or worker lifetime."""
    descriptor = os.open(Path(engine) / "use.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise ValueError("invalid engine lock")
        fcntl.flock(descriptor, (fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH) | fcntl.LOCK_NB)
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def safe_file(root, relative):
    root = Path(root)
    parts = Path(relative).parts
    if not parts or Path(relative).is_absolute() or any(p in (".", "..") for p in parts):
        raise ValueError("invalid asset path")
    current = root
    if current.is_symlink():
        raise ValueError("linked asset root")
    for part in parts:
        current = current / part
        if current.is_symlink():
            raise ValueError("linked asset")
    return current


def verify_file(path, record):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_size != record["bytes"] or info.st_size <= 0:
        raise ValueError("asset size or type mismatch")
    digest = hashlib.sha256()
    total = 0
    with path.open("rb") as source:
        while True:
            chunk = source.read(65536)
            if not chunk:
                break
            total += len(chunk)
            if total > record["bytes"]:
                raise ValueError("asset grew during verification")
            digest.update(chunk)
    if total != record["bytes"] or digest.hexdigest() != record["sha256"]:
        raise ValueError("asset digest mismatch")


def verify_assets(root: Path, manifest: dict) -> None:
    files = manifest.get("files")
    if not isinstance(files, list) or len(files) > 64:
        raise ValueError("invalid asset list")
    seen = set()
    for record in files:
        path = record["path"]
        if path in seen:
            raise ValueError("duplicate asset")
        seen.add(path)
        verify_file(safe_file(root, path), record)
