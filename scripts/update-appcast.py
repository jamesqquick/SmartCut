#!/usr/bin/env python3
"""Prepend a new Sparkle <item> into docs/appcast.xml.

Called by the release workflow after sign_update produces the EdDSA
signature for the update zip.  Inserts the new release entry directly
above the CI marker comment so that newest releases always appear first
in the feed, which is what Sparkle expects.

Usage:
    python3 scripts/update-appcast.py \\
        --version  0.1.2 \\
        --build    2 \\
        --signature BASE64_SIG \\
        --length   12345678 \\
        --appcast  docs/appcast.xml
"""
import argparse
import datetime
import sys

ITEM_TEMPLATE = """\
    <item>
      <title>SmartCut {version}</title>
      <pubDate>{pub_date}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/jamesqquick/SmartCut/releases/tag/v{version}</sparkle:releaseNotesLink>
      <enclosure
        url="https://github.com/jamesqquick/SmartCut/releases/download/v{version}/SmartCut-update.zip"
        sparkle:edSignature="{signature}"
        length="{length}"
        type="application/zip" />
    </item>"""

# Must match the comment in docs/appcast.xml exactly.
MARKER = "<!-- RELEASES PREPENDED BY CI ABOVE THIS LINE -->"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True, help="Marketing version, e.g. 0.1.2")
    parser.add_argument("--build", required=True, help="CFBundleVersion integer, e.g. 2")
    parser.add_argument("--signature", required=True, help="EdDSA base64 signature from sign_update")
    parser.add_argument("--length", required=True, help="Byte length of the update zip")
    parser.add_argument("--appcast", required=True, help="Path to appcast.xml")
    args = parser.parse_args()

    pub_date = datetime.datetime.now(datetime.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")
    new_item = ITEM_TEMPLATE.format(
        version=args.version,
        build=args.build,
        pub_date=pub_date,
        signature=args.signature,
        length=args.length,
    )

    with open(args.appcast) as f:
        content = f.read()

    if MARKER not in content:
        sys.exit(f"ERROR: CI marker not found in {args.appcast!r}. "
                 "Expected the comment: " + MARKER)

    updated = content.replace(MARKER, new_item + "\n\n    " + MARKER, 1)

    with open(args.appcast, "w") as f:
        f.write(updated)

    print(f"Inserted SmartCut {args.version} (build {args.build}) into {args.appcast}")


if __name__ == "__main__":
    main()
