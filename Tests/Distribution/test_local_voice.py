"""Validate small offline adapter inventory; never load models or run audio."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from test_architecture import ROOT, inventory

EXPECTED = {"worker.py", "worker_protocol.py", "gpt_sovits_backend.py", "voice_assets.py", "engine-assets.json", "probe.py"}


class LocalVoiceDistributionTests(unittest.TestCase):
    def copy_app(self, architecture, root):
        source = ROOT / ("dist/YeShunguangPet.app" if architecture == "arm64" else "dist/x86_64/YeShunguangPet.app")
        app = root / (architecture + ".app")
        shutil.copytree(source, app, symlinks=True)
        return app

    def verify(self, app, architecture):
        return subprocess.run(["/usr/bin/python3", str(ROOT / "scripts/verify-app.py"), str(app), "--expect-architecture", architecture], capture_output=True, text=True)

    def resign(self, app):
        subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(app)], check=True, capture_output=True)

    def test_packaged_adapter_is_complete_and_contains_no_weights_or_venv(self):
        for arch, relative in (("arm64", "dist/YeShunguangPet.app"), ("x86_64", "dist/x86_64/YeShunguangPet.app")):
            with self.subTest(architecture=arch):
                app = ROOT / relative
                folder = app / "Contents/Resources/LocalVoice"
                self.assertTrue(folder.is_dir())
                self.assertEqual({str(p.relative_to(folder)) for p in folder.rglob("*")}, EXPECTED)
                result = self.verify(app, arch)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_missing_adapter_is_rejected_even_with_valid_signature(self):
        with tempfile.TemporaryDirectory() as temporary:
            for arch in ("arm64", "x86_64"):
                app = self.copy_app(arch, Path(temporary))
                folder = app / "Contents/Resources/LocalVoice"
                if folder.exists(): shutil.rmtree(folder)
                self.resign(app)
                self.assertNotEqual(self.verify(app, arch).returncode, 0, "missing adapter accepted")

    def test_missing_file_link_weights_venv_and_bytecode_are_rejected(self):
        for arch in ("arm64", "x86_64"):
            for mutation in ("missing", "link", "s2.pth", "venv", "__pycache__", "runtime", "foreign-runtime", "foreign.so"):
                with self.subTest(architecture=arch, mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                    app = self.copy_app(arch, Path(temporary)); folder = app / "Contents/Resources/LocalVoice"
                    if mutation in ("missing", "link"):
                        (folder / "worker.py").unlink()
                        if mutation == "link": (folder / "worker.py").symlink_to("worker_protocol.py")
                    elif mutation == "foreign-runtime": (app / "Contents/Resources/runtime").mkdir()
                    elif mutation == "foreign.so": (app / "Contents/Resources/foreign.so").write_bytes(b"native")
                    elif mutation == "s2.pth": (folder / mutation).write_bytes(b"not a model")
                    else: (folder / mutation).mkdir()
                    self.resign(app)
                    self.assertNotEqual(self.verify(app, arch).returncode, 0, "invalid adapter accepted")
