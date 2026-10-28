import hashlib
import importlib.util
import json
import os
import shutil
import sys
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("prepare_voice", REPO / "tools/prepare-local-voice.py")
prepare_voice = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare_voice)


class PrepareTests(unittest.TestCase):
    def test_help_does_not_write_bytecode_into_repository_resources(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "tools").mkdir(); (root / "Resources/LocalVoice").mkdir(parents=True)
            script = root / "tools/prepare-local-voice.py"
            shutil.copyfile(REPO / "tools/prepare-local-voice.py", script)
            shutil.copyfile(REPO / "Resources/LocalVoice/voice_assets.py", root / "Resources/LocalVoice/voice_assets.py")
            env = dict(os.environ)
            env.pop("PYTHONDONTWRITEBYTECODE", None); env.pop("PYTHONPYCACHEPREFIX", None)
            result = subprocess.run([sys.executable, "-X", "pycache_prefix=" + str(root / "bytecode"), str(script), "--help"], capture_output=True, env=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(list(root.rglob("voice_assets*.pyc")), [])

    def test_active_runtime_lock_prevents_prepare_without_changing_current(self):
        import fcntl
        engine = self.settings.parent / "LocalVoice/Engine"
        engine.mkdir(parents=True)
        current = engine / "current.json"; current.write_bytes(b"old descriptor")
        script = "import fcntl,sys,time;f=open(sys.argv[1],'a');fcntl.flock(f,fcntl.LOCK_SH);print('locked',flush=True);time.sleep(30)"
        child = subprocess.Popen([sys.executable, "-c", script, str(engine / "use.lock")], stdout=subprocess.PIPE)
        try:
            self.assertEqual(child.stdout.readline(), b"locked\n")
            with patch.object(prepare_voice.platform, "machine", return_value="arm64"), patch.object(prepare_voice, "ensure_inactive"):
                with self.assertRaisesRegex(RuntimeError, "引擎"):
                    prepare_voice.prepare(self.experiment, Path("/explicit/python3.12"), self.settings, manifest=self.manifest, runner=self.runner)
            self.assertEqual(current.read_bytes(), b"old descriptor")
            self.assertFalse((engine / "Versions").exists())
        finally:
            child.terminate(); child.wait(timeout=3); child.stdout.close()

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.experiment = self.root / "experiment"
        self.experiment.mkdir()
        source = self.experiment / "upstream"
        source.mkdir()
        (source / "marker.py").write_text("UNCHANGED = True\n")
        archive = self.experiment / "source.tar.gz"
        with tarfile.open(archive, "w:gz") as target:
            target.add(source, arcname="fixed-source")
        (self.experiment / "asset.bin").write_bytes(b"asset")
        (self.experiment / "e1.pth").write_bytes(b"weight")
        # Real WAV shape, generated without external libraries.
        import wave
        with wave.open(str(self.experiment / "reference.wav"), "wb") as wav:
            wav.setparams((1, 2, 32000, 0, "NONE", "not compressed"))
            wav.writeframes(b"\x01\x00" * 96000)
        def record(path):
            return {"bytes": path.stat().st_size, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
        self.manifest = {
            "schemaVersion": 1, "profile": "gpt-sovits-v2proplus-cpu1", "sourceCommit": "b4570b876f5c086819ba84e3215472733c6a7b70",
            "sourceArchive": {"experimentPath": archive.name, **record(archive)},
            "files": [{"path": "source/asset.bin", "experimentPath": "asset.bin", **record(self.experiment / "asset.bin")}],
            "voice": {"model": {"experimentPath": "e1.pth", **record(self.experiment / "e1.pth")},
                      "reference": {"experimentPath": "reference.wav", **record(self.experiment / "reference.wav")}, "promptText": "你好"},
        }
        self.settings = self.root / "data/settings.json"
        self.commands = []

    def runner(self, command, **kwargs):
        self.commands.append(command)
        if command[1:3] == ["-m", "venv"]:
            python = Path(command[3]) / "bin/python"
            python.parent.mkdir(parents=True)
            python.write_text("fake interpreter")
            python.chmod(0o755)
        return subprocess.CompletedProcess(command, 0, stdout="3.12.14\n")

    def prepare(self):
        with patch.object(prepare_voice, "ensure_inactive"), patch.object(prepare_voice.platform, "machine", return_value="arm64"):
            return prepare_voice.prepare(self.experiment, Path("/test/python3.12"), self.settings, manifest=self.manifest, runner=self.runner)

    def test_new_venv_is_created_at_final_version_path(self):
        descriptor = self.prepare()
        current = json.loads((self.settings.parent / "LocalVoice/Engine/current.json").read_text())
        self.assertEqual(descriptor, current)
        venv = next(c[3] for c in self.commands if c[1:3] == ["-m", "venv"])
        self.assertEqual(Path(venv).parent.name, current["versionID"])
        self.assertIn("Versions", Path(venv).parts)
        self.assertNotIn("tmp", Path(venv).name)

    def test_failed_prepare_keeps_previous_current_descriptor(self):
        self.prepare()
        current = self.settings.parent / "LocalVoice/Engine/current.json"
        old = current.read_bytes()
        with patch.object(self, "runner", side_effect=RuntimeError("fake installation failure")):
            with self.assertRaises(RuntimeError):
                self.prepare()
        self.assertEqual(current.read_bytes(), old)

    def test_export_e1_preserves_known_weight_and_reference_digests(self):
        output = self.root / "visible voice"
        prepare_voice.export_voice(self.experiment, "e1", output, manifest=self.manifest)
        voice = json.loads((output / "voice.json").read_text())
        self.assertEqual(set(p.name for p in output.iterdir()), {"voice.json", "s2.pth", "reference.wav"})
        for key, filename in [("model", "s2.pth"), ("reference", "reference.wav")]:
            self.assertEqual(hashlib.sha256((output / filename).read_bytes()).hexdigest(), self.manifest["voice"][key]["sha256"])
            self.assertEqual(voice[key]["sha256"], self.manifest["voice"][key]["sha256"])
        with self.assertRaises(ValueError):
            prepare_voice.export_voice(self.experiment, "e2", self.root / "other", manifest=self.manifest)

    def test_check_never_installs_or_loads_model(self):
        self.prepare()
        with patch.object(prepare_voice.subprocess, "run", side_effect=AssertionError("must not execute")):
            self.assertEqual(prepare_voice.check(self.settings)["profile"], self.manifest["profile"])
        asset = self.settings.parent / "LocalVoice/Engine/Versions"
        next(asset.glob("*/source/asset.bin")).write_bytes(b"broken")
        with self.assertRaises(ValueError):
            prepare_voice.check(self.settings)

    def test_asset_links_and_outside_paths_are_rejected(self):
        with self.assertRaises(ValueError):
            prepare_voice.verify_assets(self.root, {"files": [{"path": "../outside", "bytes": 1, "sha256": "0" * 64}]})
        outside = self.root / "target"
        outside.write_bytes(b"asset")
        (self.root / "link").symlink_to(outside)
        with self.assertRaises(ValueError):
            prepare_voice.verify_assets(self.root, {"files": [{"path": "link", "bytes": 5, "sha256": hashlib.sha256(b"asset").hexdigest()}]})


if __name__ == "__main__":
    unittest.main()
