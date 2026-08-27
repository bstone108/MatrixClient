#!/usr/bin/env python3
"""Fail if shipped Mach-O files are missing required CPU slices.

Release packaging builds one universal .app (arm64 + x86_64). Xcode can
quietly thin a nested XCFramework (VLCKit, MatrixSDKFFI) down to the host
arch. This helper walks a bundle, reads each Mach-O header, and refuses a
"universal" artifact that is actually arm64-only.

Prefer `lipo -archs` when it is on PATH. Fall back to parsing fat/thin
headers so --self-test works on Linux.
"""

from __future__ import annotations

import argparse
import io
import os
import struct
import subprocess
import sys
import tempfile
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

FAT_MAGIC = 0xCAFEBABE
FAT_CIGAM = 0xBEBAFECA
FAT_MAGIC_64 = 0xCAFEBABF
FAT_CIGAM_64 = 0xBFBAFECA
MH_MAGIC = 0xFEEDFACE
MH_CIGAM = 0xCEFAEDFE
MH_MAGIC_64 = 0xFEEDFACF
MH_CIGAM_64 = 0xCFFAEDFE

CPU_ARCH_ABI64 = 0x01000000
CPU_TYPE_X86 = 7
CPU_TYPE_X86_64 = CPU_TYPE_X86 | CPU_ARCH_ABI64
CPU_TYPE_ARM = 12
CPU_TYPE_ARM64 = CPU_TYPE_ARM | CPU_ARCH_ABI64

MACHO_MAGICS = {
    struct.pack(">I", FAT_MAGIC),
    struct.pack(">I", FAT_MAGIC_64),
    struct.pack("<I", FAT_MAGIC),  # FAT_CIGAM as little-endian read of bytes
    struct.pack(">I", FAT_CIGAM),
    struct.pack(">I", FAT_CIGAM_64),
    struct.pack("<I", MH_MAGIC),
    struct.pack("<I", MH_MAGIC_64),
    struct.pack(">I", MH_MAGIC),
    struct.pack(">I", MH_MAGIC_64),
    b"\xfe\xed\xfa\xce",
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf",
    b"\xbf\xba\xfe\xca",
}

CANONICAL = {
    "arm64": "arm64",
    "arm64e": "arm64",
    "aarch64": "arm64",
    "x86_64": "x86_64",
    "x86_64h": "x86_64",
    "x86-64": "x86_64",
}


def canonicalize(name: str) -> str | None:
    key = name.strip().lower().replace(" ", "")
    return CANONICAL.get(key)


def cpu_type_name(cputype: int) -> str | None:
    masked = cputype & 0xFFFFFFFF
    if masked in (CPU_TYPE_ARM64, CPU_TYPE_ARM64 | 0xFF000000):
        return "arm64"
    if masked == CPU_TYPE_X86_64:
        return "x86_64"
    if (masked & ~CPU_ARCH_ABI64) == CPU_TYPE_ARM and masked & CPU_ARCH_ABI64:
        return "arm64"
    if (masked & ~CPU_ARCH_ABI64) == CPU_TYPE_X86 and masked & CPU_ARCH_ABI64:
        return "x86_64"
    return None


def parse_required(values: list[str]) -> list[str]:
    required: list[str] = []
    for raw in values:
        for part in raw.replace(",", " ").split():
            name = canonicalize(part)
            if name is None:
                raise SystemExit(f"Unknown required architecture: {part!r}")
            if name not in required:
                required.append(name)
    if not required:
        raise SystemExit("At least one --require architecture is needed.")
    return required


def is_macho(path: Path) -> bool:
    try:
        with path.open("rb") as handle:
            magic = handle.read(4)
    except OSError:
        return False
    return magic in MACHO_MAGICS


def list_macho_files(root: Path) -> list[Path]:
    if root.is_file():
        return [root] if is_macho(root) else []
    files: list[Path] = []
    for dirpath, _, filenames in os.walk(root):
        for name in filenames:
            path = Path(dirpath) / name
            if is_macho(path):
                files.append(path)
    files.sort(key=lambda path: (path.as_posix().count("/"), path.as_posix()))
    return files


def archs_from_lipo(path: Path) -> set[str] | None:
    try:
        completed = subprocess.run(
            ["lipo", "-archs", str(path)],
            check=False,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError:
        return None
    if completed.returncode != 0:
        return None
    names: set[str] = set()
    for part in completed.stdout.split():
        canon = canonicalize(part)
        if canon:
            names.add(canon)
    return names


def archs_from_header(path: Path) -> set[str]:
    with path.open("rb") as handle:
        header = handle.read(4096)
    if len(header) < 8:
        raise ValueError(f"{path}: too small to be Mach-O")
    magic = struct.unpack(">I", header[:4])[0]
    names: set[str] = set()

    if magic in (FAT_MAGIC, FAT_MAGIC_64, FAT_CIGAM, FAT_CIGAM_64):
        swapped = magic in (FAT_CIGAM, FAT_CIGAM_64)
        is_64 = magic in (FAT_MAGIC_64, FAT_CIGAM_64)
        nfat = struct.unpack(">I" if not swapped else "<I", header[4:8])[0]
        offset = 8
        entry_size = 20 if not is_64 else 32
        for _ in range(nfat):
            chunk = header[offset : offset + entry_size]
            if len(chunk) < 8:
                break
            cputype = struct.unpack(">I" if not swapped else "<I", chunk[:4])[0]
            name = cpu_type_name(cputype)
            if name:
                names.add(name)
            offset += entry_size
        return names

    thin_magic = struct.unpack("<I", header[:4])[0]
    endian = "<" if thin_magic in (MH_MAGIC, MH_MAGIC_64, MH_CIGAM, MH_CIGAM_64) else ">"
    if thin_magic in (MH_CIGAM, MH_CIGAM_64):
        endian = ">"
    if struct.unpack(">I", header[:4])[0] in (MH_MAGIC, MH_MAGIC_64):
        endian = ">"
    if struct.unpack("<I", header[:4])[0] in (MH_MAGIC, MH_MAGIC_64):
        endian = "<"
    cputype = struct.unpack(endian + "I", header[4:8])[0]
    name = cpu_type_name(cputype)
    if name:
        names.add(name)
    return names


def architectures_for(path: Path) -> set[str]:
    from_lipo = archs_from_lipo(path)
    if from_lipo is not None:
        return from_lipo
    return archs_from_header(path)


def inspect_roots(roots: list[Path], required: list[str], must_include: list[str]) -> int:
    files: list[Path] = []
    for root in roots:
        if not root.exists():
            print(f"Missing path: {root}", file=sys.stderr)
            return 1
        files.extend(list_macho_files(root))
    if not files:
        print("No Mach-O files found in: " + ", ".join(str(r) for r in roots), file=sys.stderr)
        return 1

    failures: list[str] = []
    seen_needles = {needle: False for needle in must_include}

    for path in files:
        posix = path.as_posix()
        for needle in seen_needles:
            if needle in posix:
                seen_needles[needle] = True
        try:
            found = architectures_for(path)
        except ValueError as exc:
            failures.append(str(exc))
            continue
        missing = [arch for arch in required if arch not in found]
        found_label = " ".join(sorted(found)) if found else "(none)"
        if missing:
            failures.append(
                f"{path}: has [{found_label}], missing {', '.join(missing)}"
            )
            print(f"FAIL {path}: {found_label}")
        else:
            print(f"OK   {path}: {found_label}")

    for needle, present in seen_needles.items():
        if not present:
            failures.append(
                f"No Mach-O path containing {needle!r} was found. "
                "Refusing to call this a universal build without that binary."
            )

    if failures:
        print("Universal slice check failed:", file=sys.stderr)
        for line in failures:
            print(f"  {line}", file=sys.stderr)
        print(
            "Do not ship a universal filename if a nested dependency "
            "(especially VLCKit) cannot lipo. Dual-arch jobs or arm64-only "
            "are the honest alternatives.",
            file=sys.stderr,
        )
        return 1

    print(
        f"Checked {len(files)} Mach-O file(s); all contain {' + '.join(required)}."
    )
    return 0


def _write_thin(path: Path, cputype: int) -> None:
    # MH_MAGIC_64, little-endian, Mach-O 64 header with no load commands.
    header = struct.pack("<IIIIIIII", MH_MAGIC_64, cputype, 0, 6, 0, 0, 0, 0)
    path.write_bytes(header)


def _write_fat(path: Path, cpu_types: list[int]) -> None:
    nfat = len(cpu_types)
    blob = struct.pack(">II", FAT_MAGIC, nfat)
    offset = 8 + 20 * nfat
    payload = b""
    for cputype in cpu_types:
        thin = struct.pack("<IIIIIIII", MH_MAGIC_64, cputype, 0, 6, 0, 0, 0, 0)
        blob += struct.pack(">IIIII", cputype, 0, offset, len(thin), 0)
        payload += thin
        offset += len(thin)
    path.write_bytes(blob + payload)


def self_test() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        thin = root / "thin-arm64"
        fat = root / "universal"
        intel_only = root / "thin-x86"
        nested = root / "VLCKit.framework" / "VLCKit"
        nested.parent.mkdir(parents=True)
        _write_thin(thin, CPU_TYPE_ARM64)
        _write_fat(fat, [CPU_TYPE_ARM64, CPU_TYPE_X86_64])
        _write_thin(intel_only, CPU_TYPE_X86_64)
        _write_fat(nested, [CPU_TYPE_ARM64, CPU_TYPE_X86_64])

        assert architectures_for(thin) == {"arm64"}, architectures_for(thin)
        assert architectures_for(fat) == {"arm64", "x86_64"}, architectures_for(fat)
        assert architectures_for(intel_only) == {"x86_64"}

        required = parse_required(["arm64,x86_64"])
        sink = io.StringIO()
        with redirect_stdout(sink), redirect_stderr(sink):
            assert inspect_roots([fat, nested.parent], required, ["VLCKit"]) == 0
            assert inspect_roots([thin], required, []) == 1
            assert inspect_roots([intel_only], required, []) == 1
            assert inspect_roots([fat], required, ["VLCKit"]) == 1

        script = str(Path(__file__).resolve())
        passed = subprocess.run(
            [
                sys.executable,
                script,
                "--require",
                "arm64,x86_64",
                "--must-include",
                "VLCKit",
                str(nested.parent),
            ],
            capture_output=True,
            text=True,
        )
        assert passed.returncode == 0, passed.stdout + passed.stderr

        failed = subprocess.run(
            [sys.executable, script, "--require", "arm64,x86_64", str(thin)],
            capture_output=True,
            text=True,
        )
        assert failed.returncode != 0, failed.stdout + failed.stderr
        assert "missing x86_64" in failed.stderr, failed.stderr

    print("self-test passed")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument(
        "--require",
        default="arm64,x86_64",
        help="Comma/space-separated architectures every Mach-O must contain.",
    )
    parser.add_argument(
        "--must-include",
        action="append",
        default=[],
        help="Substring that must appear in at least one Mach-O path.",
    )
    parser.add_argument("paths", nargs="*", type=Path)
    args = parser.parse_args()

    if args.self_test:
        self_test()
        return 0

    if not args.paths:
        parser.error("the following arguments are required: paths")
    required = parse_required([args.require])
    return inspect_roots(args.paths, required, args.must_include)


if __name__ == "__main__":
    raise SystemExit(main())
