import hashlib
import json
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))
import local_voice_package as package
from test_macho import binary


class EnginePackageTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(); self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name); self.runtime = self.root / "runtime"; self.experiment = self.root / "experiment"
        (self.runtime / "bin").mkdir(parents=True); self.experiment.mkdir()
        (self.runtime / "bin/python3.12").write_bytes(binary()); (self.runtime / "bin/python3.12").chmod(0o700)
        source = self.root / "source"; source.mkdir(); (source / "module.py").write_bytes(b"UNCHANGED = True\n"); (source / "LICENSE").write_bytes(b"source license")
        archive = self.experiment / "source.tar.gz"
        with tarfile.open(archive, "w:gz") as bundle: bundle.add(source, arcname="fixed-source")
        asset = self.experiment / "public.bin"; asset.write_bytes(b"public model")
        (self.experiment / "e1.pth").write_bytes(b"role only"); (self.experiment / "private.wav").write_bytes(b"reference only")
        def record(p): return dict(bytes=p.stat().st_size, sha256=hashlib.sha256(p.read_bytes()).hexdigest())
        self.metadata = self.root / "assets.json"
        self.metadata.write_text(json.dumps(dict(schemaVersion=1, profile="gpt-sovits-v2proplus-cpu1", sourceCommit="b4570b876f5c086819ba84e3215472733c6a7b70", sourceArchive=dict(experimentPath=archive.name, **record(archive)), files=[dict(path="source/public.bin", experimentPath=asset.name, **record(asset))], voice=dict(model=dict(experimentPath="e1.pth")))))
        self.output = self.root / "引擎 含空格"

    def assemble(self):
        with patch.object(package, "ASSET_METADATA", self.metadata):
            return package.assemble_engine(self.runtime, self.experiment, self.output, engine_id="engine-test", version="1.0.0")

    def test_assembly_excludes_voice_training_and_host_paths(self):
        result = self.assemble()
        self.assertEqual(result["id"], "engine-test")
        self.assertEqual((self.output / "payload/source/module.py").read_bytes(), b"UNCHANGED = True\n")
        data = (self.output / "payload/engine-assets.json").read_text()
        self.assertNotIn("experimentPath", data); self.assertNotIn(str(self.root), data)
        paths = {p.name for p in self.output.rglob("*")}
        self.assertTrue({"e1.pth", "private.wav", "venv"}.isdisjoint(paths))
        self.assertTrue((self.output / "payload/licenses/THIRD_PARTY_NOTICES.md").is_file())

    def test_manifest_is_deterministic_and_hashes_final_bytes(self):
        self.assemble(); before = (self.output / "engine.json").read_bytes()
        metadata = json.loads(before)
        package.write_engine_manifest(self.output, metadata)
        self.assertEqual((self.output / "engine.json").read_bytes(), before)
        self.assertEqual([r["path"] for r in metadata["files"]], sorted(r["path"] for r in metadata["files"]))
        target = self.output / "payload/runtime/bin/python3.12"; target.write_bytes(b"changed final signed bytes")
        changed = package.write_engine_manifest(self.output, metadata)
        record = next(r for r in changed["files"] if r["path"] == "runtime/bin/python3.12")
        self.assertEqual(record["bytes"], 26)
        self.assertEqual(record["sha256"], hashlib.sha256(b"changed final signed bytes").hexdigest())

    def test_output_is_readable_without_the_builders_uid(self):
        self.assemble()
        self.assertEqual((self.output / "payload/source/module.py").stat().st_mode & 0o777, 0o644)
        self.assertEqual((self.output / "payload/runtime/bin/python3.12").stat().st_mode & 0o777, 0o755)
        self.assertEqual((self.output / "engine.json").stat().st_mode & 0o777, 0o644)

    def test_dmg_uses_argument_array_and_keeps_source(self):
        self.assemble(); output = self.root / "独立 引擎.dmg"; calls = []
        def runner(command, **kwargs):
            calls.append(command)
            if command[1] == "create": Path(command[-1]).write_bytes(b"test image")
            return subprocess.CompletedProcess(command, 0)
        package.package_engine_dmg(self.output, output, runner=runner)
        self.assertEqual(output.read_bytes(), b"test image")
        self.assertEqual(len(calls), 2); self.assertIsInstance(calls[0], list)
        self.assertTrue(str(calls[0][-1]).endswith(".dmg"))
        self.assertTrue(Path(str(output) + ".sha256").read_text().endswith("  独立 引擎.dmg\n"))
        self.assertTrue((self.output / "engine.json").exists())
        with self.assertRaises(subprocess.CalledProcessError):
            package.package_engine_dmg(self.output, self.root / "failed.dmg", runner=lambda c, **kw: (_ for _ in ()).throw(subprocess.CalledProcessError(1,c)))
        self.assertTrue((self.output / "engine.json").exists())
