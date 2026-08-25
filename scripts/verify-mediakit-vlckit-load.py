#!/usr/bin/env python3
"""Fail packaging if MediaKit's VLCKit load command does not resolve.

dyld uses LC_LOAD_DYLIB as written. MediaKit ships with a hardcoded
@loader_path/../Frameworks/VLCKit... load (vlckit-spm / Xcode), which is a
sibling of Versions/A. The packager nests VLCKit at
Versions/A/Frameworks/VLCKit... so codesign --verify --deep --strict passes.
That nest is invisible to dyld unless the load command is rewritten.

This helper parses `otool -L` on the MediaKit binary, resolves @loader_path
relative to that binary, and checks that file. A copy of VLCKit elsewhere in
the app bundle is not enough.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

COMPAT_SUFFIX = re.compile(r"\s+\(compatibility version .*\)\s*$")
VLCKIT_MARKER = "VLCKit.framework"
OLD_LOADER_PREFIX = "@loader_path/../Frameworks/"
NEW_LOADER_PREFIX = "@loader_path/Frameworks/"


def parse_otool_l(text: str) -> list[str]:
    names: list[str] = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.endswith(":"):
            continue
        line = COMPAT_SUFFIX.sub("", line).strip()
        if line:
            names.append(line)
    return names


def vlckit_loads(names: list[str]) -> list[str]:
    return [name for name in names if VLCKIT_MARKER in name]


def rewrite_vlckit_load(name: str) -> str:
    """Map the codesign-invalid nest onto Versions/<v>/Frameworks."""
    if name.startswith(OLD_LOADER_PREFIX) and VLCKIT_MARKER in name:
        return NEW_LOADER_PREFIX + name[len(OLD_LOADER_PREFIX) :]
    return name


def resolve_loader_path(name: str, macho_path: Path) -> Path:
    if not name.startswith("@loader_path"):
        raise ValueError(
            f"MediaKit VLCKit load is {name!r}; expected @loader_path "
            "(hardcoded @loader_path is what dyld uses; rpaths are ignored)."
        )
    loader_dir = macho_path.resolve().parent
    if name == "@loader_path":
        return loader_dir
    if not name.startswith("@loader_path/"):
        raise ValueError(f"Unsupported @loader_path form: {name!r}")
    rest = name[len("@loader_path/") :]
    return Path(os.path.normpath(loader_dir / rest))


def read_otool_l(binary: Path, otool_l_path: str | None) -> str:
    if otool_l_path == "-":
        return sys.stdin.read()
    if otool_l_path:
        return Path(otool_l_path).read_text(encoding="utf-8")
    try:
        completed = subprocess.run(
            ["otool", "-L", str(binary)],
            check=True,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError as exc:
        raise SystemExit("otool is required to inspect MediaKit load commands.") from exc
    except subprocess.CalledProcessError as exc:
        sys.stderr.write(exc.stderr or exc.stdout or "")
        raise SystemExit(f"otool -L failed for {binary}") from exc
    return completed.stdout


def check_binary(binary: Path, otool_text: str) -> None:
    if not binary.is_file():
        raise SystemExit(f"MediaKit binary not found: {binary}")
    loads = vlckit_loads(parse_otool_l(otool_text))
    if not loads:
        raise SystemExit(
            f"MediaKit has no VLCKit LC_LOAD_DYLIB: {binary}\n{otool_text}"
        )
    for name in loads:
        try:
            resolved = resolve_loader_path(name, binary)
        except ValueError as exc:
            raise SystemExit(str(exc)) from exc
        print(f"MediaKit VLCKit load: {name}")
        print(f"Resolved dyld path: {resolved}")
        if not resolved.is_file():
            raise SystemExit(
                "VLCKit is missing at the path dyld will load from MediaKit. "
                "A copy elsewhere in the bundle does not count.\n"
                f"  load command: {name}\n"
                f"  resolved:     {resolved}"
            )
        print(f"OK: {resolved} exists")


def self_test() -> None:
    bad_otool = """
/tmp/MediaKit.framework/Versions/A/MediaKit:
	@rpath/MediaKit.framework/Versions/A/MediaKit (compatibility version 1.0.0, current version 1.0.0)
	@loader_path/../Frameworks/VLCKit.framework/Versions/A/VLCKit (compatibility version 3.0.0, current version 3.6.0)
	/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation (compatibility version 300.0.0, current version 2503.1.0)
"""
    good_otool = bad_otool.replace(
        "@loader_path/../Frameworks/VLCKit.framework/Versions/A/VLCKit",
        "@loader_path/Frameworks/VLCKit.framework/Versions/A/VLCKit",
    )
    loads = parse_otool_l(bad_otool)
    assert loads[0].endswith("MediaKit"), loads
    vlckit = vlckit_loads(loads)
    assert vlckit == [
        "@loader_path/../Frameworks/VLCKit.framework/Versions/A/VLCKit"
    ], vlckit
    rewritten = rewrite_vlckit_load(vlckit[0])
    assert rewritten == (
        "@loader_path/Frameworks/VLCKit.framework/Versions/A/VLCKit"
    ), rewritten
    assert rewrite_vlckit_load(rewritten) == rewritten

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        mediakit = root / "MediaKit.framework/Versions/A/MediaKit"
        nested = (
            root
            / "MediaKit.framework/Versions/A/Frameworks/VLCKit.framework/Versions/A/VLCKit"
        )
        toplevel = root / "Contents/Frameworks/VLCKit.framework/Versions/A/VLCKit"
        mediakit.parent.mkdir(parents=True)
        nested.parent.mkdir(parents=True)
        toplevel.parent.mkdir(parents=True)
        mediakit.write_bytes(b"mediakit")
        nested.write_bytes(b"nested-vlckit")
        toplevel.write_bytes(b"toplevel-vlckit")
        # 2026.8.25.1 layout: nested + top-level VLCKit exist, but LC_LOAD_DYLIB
        # still points at Versions/Frameworks (sibling of Versions/A).
        try:
            check_binary(mediakit, bad_otool)
        except SystemExit as exc:
            message = str(exc)
            assert "missing at the path dyld will load" in message, message
            assert "Versions/Frameworks/VLCKit.framework" in message, message
            # Top-level Contents/Frameworks/VLCKit must not satisfy the check.
            assert "Contents/Frameworks/VLCKit" not in message, message
        else:
            raise AssertionError("2026.8.25.1 layout must fail the dyld-path check")

        resolved_bad = resolve_loader_path(vlckit[0], mediakit)
        assert not resolved_bad.is_file(), resolved_bad
        assert resolved_bad != nested.resolve()
        assert resolved_bad != toplevel.resolve()
        assert "Versions/Frameworks/VLCKit.framework" in str(resolved_bad)
        assert toplevel.is_file() and nested.is_file()

        check_binary(mediakit, good_otool)
        resolved_good = resolve_loader_path(rewritten, mediakit)
        assert resolved_good.is_file(), resolved_good
        assert resolved_good == nested.resolve()

        script = str(Path(__file__).resolve())
        bad_file = root / "otool-bad.txt"
        good_file = root / "otool-good.txt"
        bad_file.write_text(bad_otool, encoding="utf-8")
        good_file.write_text(good_otool, encoding="utf-8")

        failed = subprocess.run(
            [
                sys.executable,
                script,
                "--binary",
                str(mediakit),
                "--otool-l",
                str(bad_file),
            ],
            capture_output=True,
            text=True,
        )
        assert failed.returncode != 0, failed.stdout + failed.stderr
        assert "missing at the path dyld will load" in failed.stderr, failed.stderr

        passed = subprocess.run(
            [
                sys.executable,
                script,
                "--binary",
                str(mediakit),
                "--otool-l",
                str(good_file),
            ],
            capture_output=True,
            text=True,
        )
        assert passed.returncode == 0, passed.stdout + passed.stderr
        assert str(nested.resolve()) in passed.stdout

        printed = subprocess.run(
            [sys.executable, script, "--print-vlckit-load"],
            input=bad_otool,
            capture_output=True,
            text=True,
        )
        assert printed.returncode == 0, printed.stderr
        assert printed.stdout.strip() == vlckit[0]

        mapped = subprocess.run(
            [sys.executable, script, "--rewrite-load", vlckit[0]],
            capture_output=True,
            text=True,
        )
        assert mapped.returncode == 0, mapped.stderr
        assert mapped.stdout.strip() == rewritten

    print("self-test passed")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument(
        "--binary",
        type=Path,
        help="MediaKit Mach-O whose VLCKit LC_LOAD_DYLIB must resolve.",
    )
    parser.add_argument(
        "--otool-l",
        help="Path to `otool -L` output, or '-' for stdin. Default: run otool.",
    )
    parser.add_argument(
        "--print-vlckit-load",
        action="store_true",
        help="Print the VLCKit load command from `otool -L` on stdin.",
    )
    parser.add_argument(
        "--rewrite-load",
        metavar="NAME",
        help="Print the nested @loader_path/Frameworks form of a VLCKit load.",
    )
    args = parser.parse_args()

    if args.self_test:
        self_test()
        return 0

    if args.rewrite_load:
        print(rewrite_vlckit_load(args.rewrite_load))
        return 0

    if args.print_vlckit_load:
        text = sys.stdin.read()
        loads = vlckit_loads(parse_otool_l(text))
        if not loads:
            print("MediaKit has no VLCKit LC_LOAD_DYLIB.", file=sys.stderr)
            sys.stderr.write(text)
            return 1
        print(loads[0])
        return 0

    if not args.binary:
        parser.error("the following arguments are required: --binary")

    otool_text = read_otool_l(args.binary, args.otool_l)
    check_binary(args.binary, otool_text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
