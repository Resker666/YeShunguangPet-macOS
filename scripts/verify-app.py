#!/usr/bin/env python3
"""Validate a single-architecture distribution bundle and its embedded framework."""
from pathlib import Path
import argparse
import hashlib
import json
import plistlib
import re
import subprocess

MINIMUM_SYSTEM_VERSION = "14.0"


def verify(app, expected_architecture=None):
    app = app.resolve()
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "io.github.resker666.yeshunguangpet.macos":
        raise ValueError("unexpected bundle identifier")
    version = info["CFBundleShortVersionString"]
    if not isinstance(version, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("invalid release version")
    if info.get("CFBundleExecutable") != "YeShunguangPet" or info.get("LSUIElement") is not True:
        raise ValueError("invalid application entry or menu-bar mode")
    if info.get("LSMinimumSystemVersion") != MINIMUM_SYSTEM_VERSION:
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
    architecture = None
    for relative in ["Contents/MacOS/YeShunguangPet", "Contents/Frameworks/PetCore.framework/Versions/A/PetCore"]:
        binary = app / relative
        slices = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).split()
        if len(slices) != 1 or slices[0] not in ["arm64", "x86_64"]:
            raise ValueError("unsupported architecture: " + relative)
        if architecture is None:
            architecture = slices[0]
        if slices[0] != architecture or (expected_architecture and slices[0] != expected_architecture):
            raise ValueError("architecture mismatch: " + relative)
        build = subprocess.check_output(["xcrun", "vtool", "-show-build", str(binary)], text=True)
        platforms = re.findall(r"^\s*platform\s+(\S+)\s*$", build, re.MULTILINE)
        minimums = re.findall(r"^\s*minos\s+(\d+(?:\.\d+){0,2})\s*$", build, re.MULTILINE)
        if platforms != ["MACOS"] or minimums not in [[MINIMUM_SYSTEM_VERSION], [MINIMUM_SYSTEM_VERSION + ".0"]]:
            raise ValueError("unexpected binary deployment target: " + relative)
        for line in subprocess.check_output(["otool", "-L", str(binary)], text=True).splitlines()[1:]:
            dependency = line.strip().split(" (", 1)[0]
            if dependency.startswith(("/System/Library/", "/usr/lib/")):
                continue
            if dependency != "@rpath/PetCore.framework/Versions/A/PetCore":
                raise ValueError("nonportable dependency: " + dependency)
    subprocess.run(["codesign", "--verify", "--strict", str(app / "Contents/Frameworks/PetCore.framework")], check=True)
    subprocess.run(["codesign", "--verify", "--strict", str(app)], check=True)
    return {"version": version, "build": info["CFBundleVersion"], "architecture": architecture,
            "minimumSystemVersion": MINIMUM_SYSTEM_VERSION, "artifactStem": "YeShunguangPet-" + version + "-macOS-" + architecture}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--expect-architecture", choices=["arm64", "x86_64"])
    args = parser.parse_args()
    try:
        print(json.dumps(verify(args.app, args.expect_architecture)))
    except (OSError, KeyError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, "App verification failed: " + str(error) + "\n")
