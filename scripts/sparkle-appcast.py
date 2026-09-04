#!/usr/bin/env python3
"""Build a per-arch Sparkle appcast for a GitHub Release DMG.

One appcast file per architecture so generate_appcast/sign_update never see
same-version arm64 and x86_64 items together. Enclosure URLs always use the
dedicated MatrixClient-VERSION-macos-ARCH.dmg name. No universal fallback.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from datetime import datetime, timezone
from email.utils import format_datetime
from xml.sax.saxutils import escape

ALLOWED_ARCHES = {"arm64", "x86_64"}
DATE_BUILD_RE = re.compile(
    r"^[0-9]{4}\.(0[1-9]|1[0-2])\.(0[1-9]|[12][0-9]|3[01])\.(0[1-9]|[1-9][0-9])$"
)
SIGN_UPDATE_RE = re.compile(
    r'sparkle:edSignature="(?P<signature>[^"]+)"\s+length="(?P<length>\d+)"'
)
REPO_DEFAULT = "bstone108/MatrixClient"


def disk_image_name(version: str, architecture: str) -> str:
    return f"MatrixClient-{version}-macos-{architecture}.dmg"


def disk_image_url(version: str, architecture: str, repo: str = REPO_DEFAULT) -> str:
    name = disk_image_name(version, architecture)
    return f"https://github.com/{repo}/releases/download/v{version}/{name}"


def appcast_name(architecture: str) -> str:
    return f"appcast-{architecture}.xml"


def parse_sign_update_output(text: str) -> tuple[str, int]:
    match = SIGN_UPDATE_RE.search(text)
    if not match:
        raise ValueError("sign_update output did not include sparkle:edSignature and length")
    return match.group("signature"), int(match.group("length"))


def validate_inputs(version: str, architecture: str, signature: str, length: int) -> None:
    if not DATE_BUILD_RE.fullmatch(version):
        raise ValueError(f"Not a date.build version: {version!r}")
    if architecture not in ALLOWED_ARCHES:
        raise ValueError(f"Unsupported architecture {architecture!r} (expected arm64 or x86_64)")
    if "universal" in architecture:
        raise ValueError("Universal Sparkle enclosures are not allowed")
    if not signature or any(ch.isspace() for ch in signature.strip()):
        raise ValueError("EdDSA signature is missing")
    if length < 1:
        raise ValueError(f"Invalid enclosure length {length}")


def render_appcast(
    *,
    version: str,
    architecture: str,
    signature: str,
    length: int,
    repo: str = REPO_DEFAULT,
    pub_date: datetime | None = None,
) -> str:
    validate_inputs(version, architecture, signature, length)
    enclosure_url = disk_image_url(version, architecture, repo)
    if f"-macos-{architecture}.dmg" not in enclosure_url:
        raise ValueError("Enclosure URL is missing the dedicated arch suffix")
    if "universal" in enclosure_url.lower():
        raise ValueError("Refusing universal enclosure URL")
    other = "x86_64" if architecture == "arm64" else "arm64"
    if f"-macos-{other}.dmg" in enclosure_url:
        raise ValueError("Enclosure URL points at the other architecture")

    stamp = pub_date or datetime.now(timezone.utc)
    if stamp.tzinfo is None:
        stamp = stamp.replace(tzinfo=timezone.utc)
    pub = format_datetime(stamp)
    title = f"Matrix Client {version}"
    return f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Matrix Client</title>
    <item>
      <title>{escape(title)}</title>
      <pubDate>{escape(pub)}</pubDate>
      <sparkle:version>{escape(version)}</sparkle:version>
      <sparkle:shortVersionString>{escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="{escape(enclosure_url)}" length="{length}" type="application/octet-stream" sparkle:edSignature="{escape(signature)}"/>
    </item>
  </channel>
</rss>
"""


def write_appcast(path: str, xml: str) -> None:
    directory = os.path.dirname(path)
    if directory:
        os.makedirs(directory, exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(xml)


def self_test() -> None:
    fake_sign = 'sparkle:edSignature="AbCd+/Ef==" length="12345678"\n'
    signature, length = parse_sign_update_output(fake_sign)
    assert signature == "AbCd+/Ef==", signature
    assert length == 12345678, length

    arm = render_appcast(
        version="2026.08.28.01",
        architecture="arm64",
        signature=signature,
        length=length,
        pub_date=datetime(2026, 8, 28, 12, 0, tzinfo=timezone.utc),
    )
    intel = render_appcast(
        version="2026.08.28.01",
        architecture="x86_64",
        signature=signature,
        length=length,
        pub_date=datetime(2026, 8, 28, 12, 0, tzinfo=timezone.utc),
    )
    assert "MatrixClient-2026.08.28.01-macos-arm64.dmg" in arm
    assert "MatrixClient-2026.08.28.01-macos-x86_64.dmg" in intel
    assert "macos-x86_64" not in arm
    assert "macos-arm64" not in intel
    assert "universal" not in arm.lower() and "universal" not in intel.lower()
    assert "sparkle:version>2026.08.28.01<" in arm
    assert 'sparkle:edSignature="AbCd+/Ef=="' in arm
    assert disk_image_url("2026.08.28.01", "arm64").endswith(
        "/v2026.08.28.01/MatrixClient-2026.08.28.01-macos-arm64.dmg"
    )
    assert appcast_name("x86_64") == "appcast-x86_64.xml"

    try:
        render_appcast(
            version="2026.8.28.1",
            architecture="universal",
            signature=signature,
            length=length,
        )
        raise AssertionError("universal architecture must be rejected")
    except ValueError:
        pass

    try:
        parse_sign_update_output("not a signature")
        raise AssertionError("invalid sign_update output must be rejected")
    except ValueError:
        pass


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--version")
    parser.add_argument("--architecture", choices=sorted(ALLOWED_ARCHES))
    parser.add_argument("--signature")
    parser.add_argument("--length", type=int)
    parser.add_argument("--sign-update-output")
    parser.add_argument(
        "--sign-update-output-stdin",
        action="store_true",
        help="Read sign_update stdout from stdin so the private key never reaches this helper.",
    )
    parser.add_argument("--repo", default=REPO_DEFAULT)
    parser.add_argument("--output")
    args = parser.parse_args()

    if args.self_test:
        self_test()
        return 0

    if not args.version or not args.architecture or not args.output:
        print("--version, --architecture, and --output are required", file=sys.stderr)
        return 1

    if args.sign_update_output_stdin:
        signature, length = parse_sign_update_output(sys.stdin.read())
    elif args.sign_update_output:
        signature, length = parse_sign_update_output(args.sign_update_output)
    else:
        if not args.signature or args.length is None:
            print(
                "Provide --sign-update-output-stdin, --sign-update-output, or both --signature and --length",
                file=sys.stderr,
            )
            return 1
        signature, length = args.signature, args.length

    xml = render_appcast(
        version=args.version,
        architecture=args.architecture,
        signature=signature,
        length=length,
        repo=args.repo,
    )
    write_appcast(args.output, xml)
    print(args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
