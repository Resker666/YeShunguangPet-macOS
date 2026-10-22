"""Check real Mach-O requirements, not just the Finder version declaration."""
from pathlib import Path
import json
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
BINARIES = ["Contents/MacOS/YeShunguangPet",
            "Contents/Frameworks/PetCore.framework/Versions/A/PetCore"]


class DeploymentTargetTests(unittest.TestCase):
    def test_both_architectures_have_sonoma_compatible_requirements(self):
        for architecture, relative in [("arm64", "dist/YeShunguangPet.app"),
                                       ("x86_64", "dist/x86_64/YeShunguangPet.app")]:
            with self.subTest(architecture=architecture):
                app = ROOT / relative
                metadata = json.loads(subprocess.check_output(
                    ["python3", str(ROOT / "scripts/verify-app.py"), str(app)], text=True))
                self.assertEqual(metadata["minimumSystemVersion"], "14.0")
                for binary in BINARIES:
                    output = subprocess.check_output(["xcrun", "vtool", "-show-build", str(app / binary)], text=True)
                    self.assertRegex(output, r"platform\s+MACOS\b")
                    minimum = re.findall(r"\bminos\s+(\d+(?:\.\d+)+)", output)
                    self.assertEqual(len(minimum), 1, output)
                    self.assertLessEqual(tuple(map(int, minimum[0].split("."))), (14, 0, 0))

    def assert_newer_binary_is_rejected(self, relative):
        with tempfile.TemporaryDirectory(prefix="ysg deployment ") as temporary:
            app = Path(temporary) / "YeShunguangPet.app"
            shutil.copytree(ROOT / "dist/YeShunguangPet.app", app, symlinks=True)
            binary = app / relative
            changed = Path(temporary) / "changed"
            subprocess.run(["xcrun", "vtool", "-set-build-version", "macos", "16.0", "27.0",
                            "-replace", "-output", str(changed), str(binary)], check=True, capture_output=True)
            shutil.copyfile(changed, binary)
            for target in [app / "Contents/Frameworks/PetCore.framework", app]:
                subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(target)],
                               check=True, capture_output=True)
            # A correct signature and unchanged Info.plist must not conceal a newer binary.
            subprocess.run(["codesign", "--verify", "--strict", str(app)], check=True)
            result = subprocess.run(["python3", str(ROOT / "scripts/verify-app.py"), str(app)],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0, "accepted a binary that requires macOS 16")
            self.assertIn("binary deployment target", result.stderr)
            self.assertIn(relative, result.stderr)

    def test_newer_main_executable_is_rejected_even_after_resigning(self):
        self.assert_newer_binary_is_rejected(BINARIES[0])

    def test_newer_embedded_framework_is_rejected_even_after_resigning(self):
        self.assert_newer_binary_is_rejected(BINARIES[1])


if __name__ == "__main__":
    unittest.main()
