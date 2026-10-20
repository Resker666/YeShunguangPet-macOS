"""Exercise the real packager and native disk images with isolated App copies.

Requires bash scripts/build-app.sh first; uses no personal App settings.
"""
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


class DistributionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ysg package 中文 ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        shutil.copytree(ROOT / "scripts", self.root / "scripts")
        shutil.copytree(ROOT / "docs", self.root / "docs")
        self.app = self.root / "dist/YeShunguangPet.app"
        shutil.copytree(ROOT / "dist/YeShunguangPet.app", self.app, symlinks=True)
        with (self.app / "Contents/Info.plist").open("rb") as stream:
            self.version = plistlib.load(stream)["CFBundleShortVersionString"]

    def package(self):
        return subprocess.run(["bash", "scripts/package-app.sh"], cwd=self.root,
                              capture_output=True, text=True, timeout=90)

    def test_explicit_missing_app_never_falls_back_to_repository_app(self):
        result = subprocess.run(["/usr/bin/python3", "scripts/smoke-app.py", "--app", str(self.root / "missing.app")],
                                cwd=self.root, capture_output=True, text=True, timeout=25)
        self.assertNotEqual(result.returncode, 0, "explicit --app was ignored and another bundle was launched")

    def test_dmg_and_zip_contain_installable_app_instructions_and_notices(self):
        result = self.package()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        stem = "YeShunguangPet-" + self.version + "-macOS-arm64"
        dist = self.root / "dist"
        dmg, archive = dist / (stem + ".dmg"), dist / (stem + ".zip")
        self.assertTrue(dmg.is_file(), "missing versioned DMG")
        self.assertTrue(archive.is_file(), "missing versioned backup ZIP")
        for artifact in [dmg, archive]:
            checksum, filename = Path(str(artifact) + ".sha256").read_text().split()
            self.assertEqual(filename, artifact.name)
            self.assertEqual(checksum, hashlib.sha256(artifact.read_bytes()).hexdigest())
        # Native extraction interprets ditto's Unicode path metadata like macOS.
        extracted = self.root / "extracted"
        subprocess.run(["ditto", "-x", "-k", str(archive), str(extracted)], check=True)
        self.assertTrue((extracted / stem / "安装说明.txt").is_file())
        self.assertTrue((extracted / stem / "YeShunguangPet.app/Contents/Resources/AppIcon.icns").is_file())
        subprocess.run(["codesign", "--verify", "--strict", str(extracted / stem / "YeShunguangPet.app")], check=True)
        attached = subprocess.check_output(["hdiutil", "attach", "-readonly", "-nobrowse", "-plist", str(dmg)])
        entity = next(e for e in plistlib.loads(attached)["system-entities"] if "mount-point" in e)
        try:
            volume = Path(entity["mount-point"])
            self.assertEqual(os.readlink(volume / "Applications"), "/Applications")
            self.assertTrue((volume / "安装说明.txt").is_file())
            self.assertTrue((volume / "YeShunguangPet.app/Contents/Resources/Notices/LICENSE.txt").is_file())
            self.assertTrue((volume / "YeShunguangPet.app/Contents/Resources/Notices/ASSET_NOTICE.md").is_file())
            subprocess.run(["codesign", "--verify", "--strict", str(volume / "YeShunguangPet.app")], check=True)
            installed = self.root / "模拟应用程序/叶瞬光桌宠.app"
            subprocess.run(["ditto", str(volume / "YeShunguangPet.app"), str(installed)], check=True)
        finally:
            subprocess.run(["hdiutil", "detach", entity["dev-entry"]], check=True)
        # Run only after ejecting the source; cwd and bundle name differ from the checkout.
        report = self.root / "installed-smoke.json"
        subprocess.run(["/usr/bin/python3", str(self.root / "scripts/smoke-app.py"), "--app", str(installed),
                        "--check-restore", "--output", str(report)], cwd="/private/tmp", check=True, timeout=45)
        self.assertTrue(json.loads(report.read_text())["restored"])

    def test_packaging_rejects_validly_resigned_developer_machine_dependency(self):
        binary = self.app / "Contents/MacOS/YeShunguangPet"
        subprocess.run(["install_name_tool", "-change", "@rpath/PetCore.framework/Versions/A/PetCore",
                        "/Users/example/Build/PetCore.framework/Versions/A/PetCore", str(binary)], check=True)
        subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(self.app)], check=True)
        result = self.package()
        self.assertNotEqual(result.returncode, 0, "packager accepted a dependency on the developer's machine")
        self.assertFalse(list((self.root / "dist").glob("*.dmg")))
        self.assertFalse(list((self.root / "dist").glob("*.zip")))


if __name__ == "__main__":
    unittest.main()
