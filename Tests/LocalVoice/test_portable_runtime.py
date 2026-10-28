"""Catch execution before integrity checking and nonportable linked payloads."""
import hashlib
import io
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))
from local_voice_runtime import materialize_symlinks, prepare_runtime, build_source_wheels, apply_relocations, finalize_runtime


class PortableRuntimeTests(unittest.TestCase):
    def test_profile_removes_only_declared_optional_backends(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); (root / "bin").mkdir(); (root / "lib").mkdir()
            (root / "lib/optional.so").write_bytes(b"optional")
            (root / "lib/required.so").write_bytes(b"required")
            finalize_runtime(root, exclude=["lib/optional.so"])
            self.assertFalse((root / "lib/optional.so").exists())
            self.assertEqual((root / "lib/required.so").read_bytes(), b"required")

    def test_finalization_removes_generated_bytecode_and_local_urls(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "bin").mkdir()
            (root / "__pycache__").mkdir()
            (root / "__pycache__/module.pyc").write_bytes(b"bytecode")
            (root / "package.dist-info").mkdir()
            (root / "package.dist-info/direct_url.json").write_bytes(b'{"url":"file:///private/build/input.whl"}')
            (root / "package.dist-info/LICENSE").write_bytes(b"license")
            finalize_runtime(root)
            self.assertEqual(list(root.rglob("*.pyc")), [])
            self.assertEqual(list(root.rglob("direct_url.json")), [])
            self.assertEqual((root / "package.dist-info/LICENSE").read_bytes(), b"license")

    def test_relocation_rejects_external_library_before_tool_execution(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "runtime"; root.mkdir()
            (root / "module.so").write_bytes(b"module")
            (root.parent / "host.dylib").write_bytes(b"host")
            calls = []
            relocation = {"file": "module.so", "addRPath": "@loader_path/..", "library": "host.dylib"}
            with self.assertRaises(ValueError):
                apply_relocations(root, [relocation], runner=lambda *a, **kw: calls.append(a))
            self.assertEqual(calls, [])

    def test_runtime_assembly_drops_build_path_config_scripts(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); (root / "downloads").mkdir()
            archive = root / "downloads/python.tar.gz"
            with tarfile.open(archive, "w:gz") as target:
                for name, data in [("python/bin/python3.12", b"binary"), ("python/bin/python3.12-config", b"#!/build/path/python")]:
                    item = tarfile.TarInfo(name); item.size = len(data); item.mode = 0o755
                    target.addfile(item, io.BytesIO(data))
            record = {"file": archive.name, "url": "https://github.com/python.tar.gz", "bytes": archive.stat().st_size,
                      "sha256": hashlib.sha256(archive.read_bytes()).hexdigest()}
            runtime = prepare_runtime(root, {"python": record, "wheels": []})
            self.assertEqual((runtime / "bin/python3.12").read_bytes(), b"binary")
            self.assertFalse((runtime / "bin/python3.12-config").exists())

    def test_source_build_checks_source_before_execution(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); (root / "sources").mkdir()
            (root / "sources/jieba.tar.gz").write_bytes(b"changed")
            calls = []
            record = {"file": "jieba.tar.gz", "url": "https://files.pythonhosted.org/jieba.tar.gz", "bytes": 7, "sha256": "0" * 64}
            with self.assertRaises(ValueError):
                build_source_wheels(root / "python", [record], root, runner=lambda *a, **kw: calls.append(a))
            self.assertEqual(calls, [])

    def test_download_digest_mismatch_never_executes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            downloads = root / "downloads"; downloads.mkdir()
            (downloads / "python.tar.gz").write_bytes(b"modified archive")
            calls = []
            lock = {"python": {"file": "python.tar.gz", "url": "https://github.com/astral-sh/python-build-standalone/releases/download/fixed/python.tar.gz",
                               "bytes": 16, "sha256": "0" * 64}, "wheels": []}
            with self.assertRaises(ValueError):
                prepare_runtime(root, lock, runner=lambda *a, **kw: calls.append(a))
            self.assertEqual(calls, [])
            self.assertFalse((root / "runtime").exists())

    def test_symlink_materialization_rejects_outside_target(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "runtime"; root.mkdir()
            target = root / "real"; target.write_bytes(b"python")
            (root / "alias").symlink_to("real")
            materialize_symlinks(root)
            self.assertFalse((root / "alias").is_symlink())
            self.assertEqual((root / "alias").read_bytes(), b"python")
            outside = root.parent / "outside"; outside.write_bytes(b"host")
            (root / "bad").symlink_to(outside)
            with self.assertRaises(ValueError):
                materialize_symlinks(root)
            self.assertEqual(outside.read_bytes(), b"host")

    def test_cyclic_link_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "cycle").symlink_to("cycle")
            with self.assertRaises(ValueError):
                materialize_symlinks(root)
