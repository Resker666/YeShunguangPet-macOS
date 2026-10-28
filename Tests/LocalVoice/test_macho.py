"""Catch host dependencies and OS floors; dylib identity is not a load."""
import struct
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))
from local_voice_macho import audit_macho_tree


def binary(*, minimum=0x000e0000, load=None, identity=None, rpath=None):
    commands = [struct.pack("<6I", 0x32, 24, 1, minimum, 0x000e0000, 0)]
    for kind, value, header in ((0xc, load, 24), (0xd, identity, 24), (0x8000001c, rpath, 12)):
        if value is None:
            continue
        encoded = value.encode() + b"\0"
        size = (header + len(encoded) + 7) // 8 * 8
        command = struct.pack("<3I", kind, size, header) + b"\0" * (header - 12) + encoded
        commands.append(command.ljust(size, b"\0"))
    payload = b"".join(commands)
    return struct.pack("<8I", 0xfeedfacf, 0x100000c, 0, 6, len(commands), len(payload), 0, 0) + payload


class MachOTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def test_native_audit_rejects_external_load_and_newer_os(self):
        target = self.root / "extension.so"
        for data in (binary(minimum=0x001b0000), binary(load="/opt/homebrew/lib/libhost.dylib"),
                     binary(load="@rpath/missing.dylib", rpath="@loader_path")):
            with self.subTest(data=data):
                target.write_bytes(data)
                with self.assertRaises(ValueError):
                    audit_macho_tree(self.root)

    def test_dylib_id_is_not_a_load_dependency(self):
        (self.root / "extension.so").write_bytes(binary(identity="/build/machine/libname.dylib", load="/usr/lib/libSystem.B.dylib"))
        report = audit_macho_tree(self.root)
        self.assertEqual(report["machOFiles"], 1)
        self.assertEqual(report["files"][0]["slices"][0]["architecture"], "arm64")
        self.assertEqual(report["files"][0]["slices"][0]["minimumOS"], "14.0.0")

    def test_loader_relative_dependency_is_resolved_inside_root(self):
        (self.root / "extension.so").write_bytes(binary(load="@rpath/libvoice.dylib", rpath="@loader_path/lib"))
        (self.root / "lib").mkdir()
        (self.root / "lib/libvoice.dylib").write_bytes(binary())
        report = audit_macho_tree(self.root)
        self.assertEqual(report["machOFiles"], 2)

    def test_transitive_library_inherits_loading_extension_rpaths(self):
        (self.root / "extension.so").write_bytes(binary(load="@rpath/parent.dylib", rpath="@loader_path/lib"))
        (self.root / "lib").mkdir()
        (self.root / "lib/parent.dylib").write_bytes(binary(load="@rpath/child.dylib"))
        (self.root / "lib/child.dylib").write_bytes(binary())
        self.assertEqual(audit_macho_tree(self.root)["machOFiles"], 3)

    def test_truncated_macho_cannot_pass_audit(self):
        (self.root / "bad.so").write_bytes(binary()[:40])
        with self.assertRaises(ValueError):
            audit_macho_tree(self.root)
