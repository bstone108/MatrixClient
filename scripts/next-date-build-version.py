#!/usr/bin/env python3
"""Compute MatrixClient date.build versions for real releases only.

Format: YYYY.M.D.N in America/Chicago (unpadded month and day).
N resets each Central-time calendar day and is max(existing)+1 for that prefix,
or 1 if none.

Existing N values come from git tags and GitHub releases. Pull-request / CI
verification builds must not call this helper to assign a version: those runs
do not increment N and must not look like a shipped date.build.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime
from typing import Iterable
from zoneinfo import ZoneInfo

CHICAGO = ZoneInfo("America/Chicago")

# Unpadded month/day. Rejects 2026.08.24.1 and leftover 0.1.0.
DATE_BUILD_RE = re.compile(
    r"^v?(?P<version>"
    r"(?P<year>\d{4})\."
    r"(?P<month>[1-9]|1[0-2])\."
    r"(?P<day>[1-9]|[12]\d|3[01])\."
    r"(?P<n>[1-9]\d*)"
    r")$"
)


def chicago_now(now: datetime | None = None) -> datetime:
    if now is None:
        return datetime.now(CHICAGO)
    if now.tzinfo is None:
        return now.replace(tzinfo=CHICAGO)
    return now.astimezone(CHICAGO)


def date_prefix(now: datetime | None = None) -> str:
    stamp = chicago_now(now)
    return f"{stamp.year}.{stamp.month}.{stamp.day}"


def parse_date_build_version(value: str) -> str:
    match = DATE_BUILD_RE.fullmatch(value.strip())
    if not match:
        raise ValueError(
            f"Not a date.build version (YYYY.M.D.N, unpadded month/day): {value!r}"
        )
    return match.group("version")


def version_pattern(prefix: str) -> re.Pattern[str]:
    # Do not use a word boundary before the version: tags are vYYYY.M.D.N, and
    # \b does not split between 'v' and a digit. Ignore padded 2026.08.24.N
    # when the prefix is 2026.8.24, and ignore leftover 0.1.0 artifacts.
    return re.compile(rf"(?:^|[^0-9])(?:v)?{re.escape(prefix)}\.(\d+)(?=$|[^0-9])")


def extract_build_numbers(prefix: str, texts: Iterable[str]) -> set[int]:
    pattern = version_pattern(prefix)
    found: set[int] = set()
    for text in texts:
        if not text:
            continue
        for match in pattern.finditer(str(text).strip()):
            number = int(match.group(1))
            if number >= 1:
                found.add(number)
    return found


def next_version(prefix: str, numbers: Iterable[int]) -> str:
    values = [number for number in numbers if number >= 1]
    nxt = (max(values) + 1) if values else 1
    return f"{prefix}.{nxt}"


def run_command(argv: list[str]) -> str:
    try:
        completed = subprocess.run(
            argv,
            check=False,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError:
        return ""
    if completed.returncode != 0:
        return ""
    return completed.stdout


def github_repo() -> str:
    return os.environ.get("GITHUB_REPOSITORY") or os.environ.get("GH_REPO") or ""


def collect_git_tag_texts() -> list[str]:
    texts = [run_command(["git", "tag", "-l"])]
    remote = os.environ.get("GIT_DIR_REMOTE", "origin")
    ls_remote = run_command(["git", "ls-remote", "--tags", remote])
    if not ls_remote:
        repo = github_repo()
        if repo:
            ls_remote = run_command(
                ["git", "ls-remote", "--tags", f"https://github.com/{repo}.git"]
            )
    texts.append(ls_remote)
    names: list[str] = []
    for blob in texts:
        for line in blob.splitlines():
            line = line.strip()
            if not line or line.endswith("^{}"):
                continue
            if "\t" in line:
                line = line.split("\t", 1)[1]
            names.append(line.rsplit("/", 1)[-1])
    return names


def collect_github_release_texts() -> list[str]:
    argv = ["gh", "release", "list", "--limit", "1000", "--json", "tagName,name"]
    repo = github_repo()
    if repo:
        argv.extend(["--repo", repo])
    raw = run_command(argv)
    if not raw.strip():
        return []
    try:
        releases = json.loads(raw)
    except json.JSONDecodeError:
        return [raw]
    names: list[str] = []
    for release in releases:
        names.append(str(release.get("tagName") or ""))
        names.append(str(release.get("name") or ""))
    return names


def collect_existing_numbers(prefix: str) -> set[int]:
    texts: list[str] = []
    texts.extend(collect_git_tag_texts())
    texts.extend(collect_github_release_texts())
    return extract_build_numbers(prefix, texts)


def self_test() -> None:
    august = datetime(2026, 8, 24, 18, 0, tzinfo=CHICAGO)
    january = datetime(2026, 1, 5, 9, 0, tzinfo=CHICAGO)
    assert date_prefix(august) == "2026.8.24", date_prefix(august)
    assert date_prefix(january) == "2026.1.5", date_prefix(january)

    utc_still_24th = datetime(2026, 8, 25, 4, 30, tzinfo=ZoneInfo("UTC"))
    assert date_prefix(utc_still_24th) == "2026.8.24", date_prefix(utc_still_24th)
    utc_25th = datetime(2026, 8, 25, 5, 0, tzinfo=ZoneInfo("UTC"))
    assert date_prefix(utc_25th) == "2026.8.25", date_prefix(utc_25th)

    prefix = "2026.8.24"
    samples = [
        "v2026.8.24.1",
        "MatrixClient-2026.8.24.2-macos-arm64",
        "MatrixClient 2026.8.24.4",
        "MatrixClient-0.1.0-macos-arm64",
        "MatrixClient-ci-macos-arm64",
        "v2026.08.24.9",
        "v2026.8.24.10",
    ]
    numbers = extract_build_numbers(prefix, samples)
    assert numbers == {1, 2, 4, 10}, numbers
    assert next_version(prefix, numbers) == "2026.8.24.11"
    assert next_version(prefix, set()) == "2026.8.24.1"
    assert parse_date_build_version("v2026.8.24.1") == "2026.8.24.1"
    assert parse_date_build_version("2026.8.24.12") == "2026.8.24.12"
    for invalid in ("0.1.0", "v2026.08.24.1", "ci", "v1.0.0", "2026.8.24"):
        try:
            parse_date_build_version(invalid)
        except ValueError:
            continue
        raise AssertionError(f"expected {invalid!r} to be rejected")
    print("self-test passed")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument(
        "--from-tag",
        help="Use this existing vYYYY.M.D.N tag as the release version (no increment).",
    )
    parser.add_argument(
        "--prefix",
        help="Override YYYY.M.D prefix (testing). Default: America/Chicago today.",
    )
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0

    if args.from_tag:
        try:
            version = parse_date_build_version(args.from_tag)
        except ValueError as exc:
            print(str(exc), file=sys.stderr)
            return 1
        print(version)
        return 0

    prefix = args.prefix or date_prefix()
    numbers = collect_existing_numbers(prefix)
    version = next_version(prefix, numbers)
    print(version)
    if os.environ.get("MATRIXCLIENT_VERSION_DEBUG"):
        print(
            f"prefix={prefix} existing={sorted(numbers)} next={version}",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
