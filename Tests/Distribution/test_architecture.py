"""Real cross-build and packaging checks; no Intel execution is claimed."""
from pathlib import Path
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def inventory(app):
    return {str(p.relative_to(app)): os.readlink(p) if p.is_symlink() else hashlib.sha256(p.read_bytes()).hexdigest()
            for p in app.rglob("*") if p.is_symlink() or p.is_file()}


class BuildArchitectureTests(unittest.TestCase):
    def test_intel_build_preserves_existing_arm_bundle(self):
        # Inside ignored .build so the real build script can read Git provenance.
        with tempfile.TemporaryDirectory(prefix="cross build 中文 ", dir=ROOT / ".build") as temporary:
            work = Path(temporary)
            for name in ["Sources", "Resources", "Tests", "YeShunguangPet.xcodeproj", "scripts", "docs"]:
                shutil.copytree(ROOT / name, work / name)
            for name in ["LICENSE", "ASSET_NOTICE.md"]:
                shutil.copy2(ROOT / name, work / name)
            arm = work / "dist/YeShunguangPet.app"
            shutil.copytree(ROOT / "dist/YeShunguangPet.app", arm, symlinks=True)
            before = inventory(arm)
            result = subprocess.run(["bash", "scripts/build-app.sh", "x86_64"], cwd=work,
                                    capture_output=True, text=True, timeout=120)
            self.assertEqual(result.returncode, 0, (result.stdout + result.stderr)[-5000:])
            intel = work / "dist/x86_64/YeShunguangPet.app"
            self.assertTrue(intel.is_dir(), "build ignored x86_64 output selection")
            for relative in ["Contents/MacOS/YeShunguangPet", "Contents/Frameworks/PetCore.framework/Versions/A/PetCore"]:
                self.assertEqual(subprocess.check_output(["lipo", "-archs", str(intel / relative)], text=True).strip(), "x86_64")
            self.assertEqual(inventory(arm), before, "Intel build modified the existing ARM App")


class ArchitecturePackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="intel package 中文 ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in ["scripts", "docs"]:
            shutil.copytree(ROOT / name, self.root / name)
        self.arm = self.root / "dist/YeShunguangPet.app"
        self.intel = self.root / "dist/x86_64/YeShunguangPet.app"
        shutil.copytree(ROOT / "dist/YeShunguangPet.app", self.arm, symlinks=True)
        shutil.copytree(ROOT / "dist/x86_64/YeShunguangPet.app", self.intel, symlinks=True)

    def test_verifier_recognizes_intel_bundle(self):
        result = subprocess.run(["/usr/bin/python3", "scripts/verify-app.py", str(self.intel)], cwd=self.root,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        metadata = json.loads(result.stdout)
        self.assertEqual(metadata["architecture"], "x86_64")
        self.assertTrue(metadata["artifactStem"].endswith("-macOS-x86_64"))

    def test_intel_package_contains_intel_app_and_preserves_arm_bundle(self):
        before = inventory(self.arm)
        result = subprocess.run(["bash", "scripts/package-app.sh", "x86_64"], cwd=self.root,
                                capture_output=True, text=True, timeout=90)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        version = plistlib.loads((self.intel / "Contents/Info.plist").read_bytes())["CFBundleShortVersionString"]
        stem = "YeShunguangPet-" + version + "-macOS-x86_64"
        for suffix in ["dmg", "zip"]:
            artifact = self.root / "dist" / (stem + "." + suffix)
            self.assertTrue(artifact.is_file(), "missing Intel " + suffix)
            checksum, filename = Path(str(artifact) + ".sha256").read_text().split()
            self.assertEqual(filename, artifact.name)
            self.assertEqual(checksum, hashlib.sha256(artifact.read_bytes()).hexdigest())
        extracted = self.root / "extracted"
        subprocess.run(["ditto", "-x", "-k", str(self.root / "dist" / (stem + ".zip")), str(extracted)], check=True)
        self.assertEqual(inventory(extracted / stem / "YeShunguangPet.app"), inventory(self.intel))
        entity = next(e for e in plistlib.loads(subprocess.check_output([
            "hdiutil", "attach", "-readonly", "-nobrowse", "-plist", str(self.root / "dist" / (stem + ".dmg"))
        ]))["system-entities"] if "mount-point" in e)
        try:
            self.assertEqual(inventory(Path(entity["mount-point"]) / "YeShunguangPet.app"), inventory(self.intel))
        finally:
            subprocess.run(["hdiutil", "detach", entity["dev-entry"]], check=True)
        self.assertEqual(inventory(self.arm), before)

    def test_mixed_main_and_framework_architectures_are_rejected(self):
        relative = "Contents/Frameworks/PetCore.framework/Versions/A/PetCore"
        (self.arm / relative).write_bytes((self.intel / relative).read_bytes())
        for target in [self.arm / "Contents/Frameworks/PetCore.framework", self.arm]:
            subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(target)], check=True)
        result = subprocess.run(["/usr/bin/python3", "scripts/verify-app.py", str(self.arm)], cwd=self.root,
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0, "mixed-architecture bundle was accepted")

    def test_architecture_selection_cannot_mislabel_a_bundle(self):
        shutil.rmtree(self.arm)
        shutil.copytree(self.intel, self.arm, symlinks=True)
        result = subprocess.run(["bash", "scripts/package-app.sh", "arm64"], cwd=self.root,
                                capture_output=True, text=True, timeout=90)
        self.assertNotEqual(result.returncode, 0, "Intel App was accepted as an ARM request")
        self.assertFalse(list((self.root / "dist").glob("*.dmg")))


if __name__ == "__main__":
    unittest.main()
