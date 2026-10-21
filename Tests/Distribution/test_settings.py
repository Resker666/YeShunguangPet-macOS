"""Exercise migration and scaled settings with the standalone ARM App."""
from pathlib import Path
import importlib.util
import json
import shutil
import tempfile
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("pet_smoke", ROOT / "scripts/smoke-app.py")
SMOKE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SMOKE)


class StandaloneSettingsTests(unittest.TestCase):
    def test_imported_copy_restores_and_missing_copy_falls_back(self):
        app = ROOT / "dist/YeShunguangPet.app"
        binary = app / "Contents/MacOS/YeShunguangPet"
        with tempfile.TemporaryDirectory(prefix="ysg imported restart ") as temporary:
            work = Path(temporary)
            source = work / "original"
            shutil.copytree(app / "Contents/Resources/Pets/YeShunguang", source)
            manifest = json.loads((source / "pet.json").read_text())
            manifest.update(id="imported-regression", name="Imported regression")
            (source / "pet.json").write_text(json.dumps(manifest))
            identifier = str(uuid.uuid4()).upper()
            managed = work / "Skins" / identifier
            # Prepare the same layout produced by SkinLibrary's native tests.
            shutil.copytree(source, managed)
            shutil.rmtree(source)
            settings = work / "settings.json"
            settings.write_text(json.dumps({"schemaVersion": 3, "preferences": {"scale": .5, "alwaysOnTop": False},
                                           "selectedSkinID": identifier}))
            for sequence in [1, 2]:
                metrics = SMOKE.run_once(binary, work, sequence)
                self.assertEqual(metrics["skinID"], "imported-regression")
                self.assertEqual(metrics["window"], {"width": 96, "height": 104})
                self.assertEqual(json.loads(settings.read_text())["selectedSkinID"], identifier)
            shutil.rmtree(managed)
            fallback = SMOKE.run_once(binary, work, 3)
            self.assertEqual(fallback["skinID"], "ye-shunguang")
            self.assertIsNone(json.loads(settings.read_text()).get("selectedSkinID"))

    def test_legacy_position_and_new_preferences_survive_real_restarts(self):
        binary = ROOT / "dist/YeShunguangPet.app/Contents/MacOS/YeShunguangPet"
        with tempfile.TemporaryDirectory(prefix="ysg settings ") as temporary:
            work = Path(temporary)
            settings = work / "settings.json"
            # First run discovers the actual screen in this isolated config.
            first = SMOKE.run_once(binary, work, 1)
            config = json.loads(settings.read_text())
            position = config["placement"]
            position["x"] = position["visibleX"] + 24
            position["y"] = position["visibleY"] + 24
            settings.write_text(json.dumps({"schemaVersion": 1, "placement": position}))
            migrated_metrics = SMOKE.run_once(binary, work, 2)
            migrated = json.loads(settings.read_text())
            self.assertEqual(migrated["schemaVersion"], 8)
            self.assertEqual(migrated["preferences"], {"scale": 1, "alwaysOnTop": True, "lookAtMouse": True,
                                                      "automaticActions": False, "automaticActionIntervalSeconds": 60,
                                                      "desktopRoaming": False, "roamIntervalSeconds": 75, "speechEnabled": False, "keyboardShortcuts": []})
            self.assertTrue(migrated_metrics["lookAtMouseEnabled"])
            self.assertGreater(migrated_metrics["gazeSamples"], 0)
            self.assertEqual(migrated["placement"], position)
            preferences = {"scale": 1.5, "alwaysOnTop": False, "lookAtMouse": False,
                           "automaticActions": True, "automaticActionIntervalSeconds": 15,
                           "desktopRoaming": True, "roamIntervalSeconds": 20, "speechEnabled": True, "keyboardShortcuts": []}
            migrated["preferences"] = preferences
            settings.write_text(json.dumps(migrated))
            for sequence in [3, 4]:
                actual = SMOKE.run_once(binary, work, sequence)
                self.assertEqual(actual["window"], {"width": 288, "height": 312})
                saved = json.loads(settings.read_text())
                self.assertEqual(saved["preferences"], preferences)
                self.assertFalse(actual["lookAtMouseEnabled"])
                self.assertEqual(actual["gazeSamples"], 0)
                self.assertTrue(actual["automaticActionsEnabled"])
                self.assertEqual(actual["automaticActionIntervalSeconds"], 15)
                self.assertEqual(actual["automaticActionCount"], 0)
                self.assertTrue(actual["desktopRoamingEnabled"])
                self.assertEqual(actual["roamIntervalSeconds"], 20)
                self.assertEqual(actual["roamingCount"], 0)
                self.assertTrue(actual["speechEnabled"])
                self.assertEqual(actual["speechShownCount"], 0)
                self.assertFalse(actual["quietMode"])
                self.assertEqual(saved["placement"], position)
            self.assertEqual(first["window"], {"width": 192, "height": 208})


if __name__ == "__main__":
    unittest.main()
