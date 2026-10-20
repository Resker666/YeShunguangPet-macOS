#!/usr/bin/env python3
"""Validate this arm64 distribution bundle without a runtime checkout dependency."""
from pathlib import Path
import argparse
import hashlib
import json
import plistlib
import re
import subprocess


def verify(app):
    app = app.resolve()
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "io.github.resker666.yeshunguangpet.macos":
        raise ValueError("unexpected bundle identifier")
    version = info["CFBundleShortVersionString"]
    if not isinstance(version, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("invalid release version")
    if info.get("CFBundleExecutable") != "YeShunguangPet" or info.get("LSUIElement") is not True:
        raise ValueError("invalid application entry or menu-bar mode")
    if info.get("LSMinimumSystemVersion") != "15.0":
        raise ValueError("unexpected deployment target")
    resources = app / "Contents/Resources"
    for filename, digest in [
        ("pet.json", "70052fd6a39c3cbe3396369f9b19d5501c236b4abb18a56d3705642ed3e08811"),
        ("spritesheet.png", "42fbb6129741a7468526ad0cad27df82ee3939be140c768d3f431cc0c9a45c2d"),
    ]:
        if hashlib.sha256((resources / "Pets/YeShunguang" / filename).read_bytes()).hexdigest() != digest:
            raise ValueError("legacy resource changed: " + filename)
    if info.get("CFBundleIconFile") != "AppIcon" or (resources / "AppIcon.icns").stat().st_size < 8:
        raise ValueError("missing application icon")
    for name in ["LICENSE.txt", "ASSET_NOTICE.md", "resource-provenance.md"]:
        if (resources / "Notices" / name).stat().st_size == 0:
            raise ValueError("empty notice: " + name)
    for relative in ["Contents/MacOS/YeShunguangPet", "Contents/Frameworks/PetCore.framework/Versions/A/PetCore"]:
        binary = app / relative
        if subprocess.check_output(["lipo", "-archs", str(binary)], text=True).strip() != "arm64":
            raise ValueError("unexpected architecture: " + relative)
        for line in subprocess.check_output(["otool", "-L", str(binary)], text=True).splitlines()[1:]:
            dependency = line.strip().split(" (", 1)[0]
            if dependency.startswith(("/System/Library/", "/usr/lib/")):
                continue
            if dependency != "@rpath/PetCore.framework/Versions/A/PetCore":
                raise ValueError("nonportable dependency: " + dependency)
    subprocess.run(["codesign", "--verify", "--strict", str(app / "Contents/Frameworks/PetCore.framework")], check=True)
    subprocess.run(["codesign", "--verify", "--strict", str(app)], check=True)
    return {"version": version, "build": info["CFBundleVersion"], "architecture": "arm64",
            "minimumSystemVersion": "15.0", "artifactStem": "YeShunguangPet-" + version + "-macOS-arm64"}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(verify(args.app)))
    except (OSError, KeyError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, "App verification failed: " + str(error) + "\n")
