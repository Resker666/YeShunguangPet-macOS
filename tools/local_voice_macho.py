"""Read Mach-O load commands, then audit the actual in-payload load closure."""
import json
import struct
from pathlib import Path

MAGICS = {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"}
LOADS = {0xc, 0x80000018, 0x8000001f, 0x80000023}


def _version(value):
    return (value >> 16, (value >> 8) & 255, value & 255)


def _slices(data):
    magic = data[:4]
    if magic in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
        wide = magic[-1] == 0xbf
        if len(data) < 8:
            raise ValueError("truncated fat Mach-O")
        count = struct.unpack_from(">I", data, 4)[0]
        stride = 32 if wide else 20
        if not 1 <= count <= 16 or 8 + count * stride > len(data):
            raise ValueError("invalid fat Mach-O")
        for n in range(count):
            row = 8 + n * stride
            offset, size = struct.unpack_from(">QQ" if wide else ">II", data, row + 8)
            if offset < 8 + count * stride or size < 32 or offset + size > len(data):
                raise ValueError("invalid fat slice")
            yield data[offset:offset + size]
    else:
        yield data


def _parse(data):
    endian = "<" if data[:4] == b"\xcf\xfa\xed\xfe" else ">"
    if data[:4] not in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf") or len(data) < 32:
        raise ValueError("unsupported or truncated Mach-O")
    _, cpu, _, file_type, count, length, _, _ = struct.unpack_from(endian + "8I", data)
    if count > 10000 or 32 + length > len(data):
        raise ValueError("truncated Mach-O commands")
    result = {"architecture": {0x100000c: "arm64", 0x1000007: "x86_64"}.get(cpu, str(cpu)), "fileType": file_type, "loads": [], "rpaths": []}
    minimum = None
    offset = 32
    for _ in range(count):
        if offset + 8 > 32 + length:
            raise ValueError("truncated load command")
        kind, size = struct.unpack_from(endian + "2I", data, offset)
        if size < 8 or size % 4 or offset + size > 32 + length:
            raise ValueError("invalid load command")
        command = data[offset:offset + size]
        if kind in LOADS or kind == 0x8000001c:
            if size < 12:
                raise ValueError("invalid string command")
            start = struct.unpack_from(endian + "I", command, 8)[0]
            if not (24 if kind in LOADS else 12) <= start < size or b"\0" not in command[start:]:
                raise ValueError("invalid load path")
            path = command[start:].split(b"\0", 1)[0].decode("utf-8")
            result["loads" if kind in LOADS else "rpaths"].append(path)
        elif kind == 0x32:
            if size < 24 or struct.unpack_from(endian + "I", command, 8)[0] != 1:
                raise ValueError("non-macOS binary")
            minimum = _version(struct.unpack_from(endian + "I", command, 12)[0])
        elif kind == 0x24:
            if size < 16:
                raise ValueError("invalid OS floor")
            minimum = _version(struct.unpack_from(endian + "I", command, 8)[0])
        offset += size
    if offset != 32 + length or minimum is None:
        raise ValueError("missing OS floor or malformed commands")
    result["minimumOS"] = ".".join(map(str, minimum))
    return result


def audit_macho_tree(root: Path, *, minimum_os=(14, 0)) -> dict:
    root = Path(root).resolve(strict=True)
    records = {}
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise ValueError("linked runtime payload: " + str(path.relative_to(root)))
        if not path.is_file():
            continue
        with path.open("rb") as source:
            magic = source.read(4)
        if magic not in MAGICS:
            continue
        rows = [_parse(s) for s in _slices(path.read_bytes())]
        if not any(s["architecture"] == "arm64" for s in rows):
            raise ValueError("binary has no arm64 slice: " + str(path.relative_to(root)))
        for row in rows:
            if row["architecture"] == "arm64" and tuple(map(int, row["minimumOS"].split("."))) > tuple(minimum_os) + (0,) * (3-len(minimum_os)):
                raise ValueError("newer minimum OS: " + str(path.relative_to(root)) + " " + row["minimumOS"])
        records[path] = rows
    executable = root / "bin/python3.12"
    executable_rpaths = [p for row in records.get(executable, []) if row["architecture"] == "arm64" for p in row["rpaths"]]

    def expand(value, owner):
        if value.startswith("@loader_path/"):
            return owner.parent / value[len("@loader_path/"):]
        if value.startswith("@executable_path/"):
            return executable.parent / value[len("@executable_path/"):]
        if value.startswith("/"):
            return Path(value)
        return None

    def system(value):
        return value.startswith(("/usr/lib/", "/System/Library/"))

    visited = set()
    reached = set()
    executable_search = tuple(expand(p, executable) for p in executable_rpaths if expand(p, executable) is not None)

    def walk(path, inherited):
        row = next(r for r in records[path] if r["architecture"] == "arm64")
        local = [expand(p, path) for p in row["rpaths"]]
        search = tuple(dict.fromkeys(p for p in local + list(inherited) if p is not None))
        key = (path, search)
        if key in visited:
            return
        visited.add(key); reached.add(path)
        resolved = set(row.get("resolvedLoads", []))
        for dependency in row["loads"]:
            if system(dependency):
                resolved.add(dependency)
                continue
            if dependency.startswith("@rpath/"):
                candidates = [base / dependency[len("@rpath/"):] for base in search]
            else:
                target = expand(dependency, path)
                candidates = [] if target is None else [target]
            destination = None
            for candidate in candidates:
                candidate = candidate.resolve()
                if candidate.is_relative_to(root) and candidate in records and any(r["architecture"] == "arm64" for r in records[candidate]):
                    destination = candidate
                    break
            if destination is None:
                raise ValueError("unresolved or external load: " + str(path.relative_to(root)) + " -> " + dependency)
            resolved.add(str(destination.relative_to(root)))
            # dyld carries the loader chain's runpath stack to dependencies.
            walk(destination, search)
        row["resolvedLoads"] = sorted(resolved)

    roots = [p for p, rows in records.items() if p.name.endswith(".so") or any(r["fileType"] == 2 for r in rows)]
    for path in roots:
        walk(path, executable_search)
    for path in records:
        if path not in reached:
            walk(path, executable_search)
    return {"machOFiles": len(records), "files": [{"path": str(p.relative_to(root)), "slices": rows} for p, rows in records.items()]}


if __name__ == "__main__":
    import argparse
    p = argparse.ArgumentParser(); p.add_argument("root", type=Path)
    print(json.dumps(audit_macho_tree(p.parse_args().root), ensure_ascii=False, indent=2))
