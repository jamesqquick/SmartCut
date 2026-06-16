#!/usr/bin/env bash
# package-dmg.sh — Build a distributable DMG from a SmartCut.app export.
#
# Usage:
#   ./scripts/package-dmg.sh <path/to/SmartCut.app> <output/SmartCut.dmg> <version>
#
# Requires: create-dmg (brew install create-dmg)

set -euo pipefail

APP_PATH="${1:?Usage: $0 <SmartCut.app> <output.dmg> <version>}"
DMG_PATH="${2:?Usage: $0 <SmartCut.app> <output.dmg> <version>}"
VERSION="${3:?Usage: $0 <SmartCut.app> <output.dmg> <version>}"

if ! command -v create-dmg &>/dev/null; then
  echo "error: create-dmg not found. Install with: brew install create-dmg" >&2
  exit 1
fi

echo "Packaging SmartCut v${VERSION} → ${DMG_PATH}"

create-dmg \
  --volname "SmartCut ${VERSION}" \
  --volicon "${APP_PATH}/Contents/Resources/AppIcon.icns" \
  --window-pos 200 120 \
  --window-size 660 400 \
  --icon-size 128 \
  --icon "SmartCut.app" 165 185 \
  --hide-extension "SmartCut.app" \
  --app-drop-link 495 185 \
  --no-internet-enable \
  "${DMG_PATH}" \
  "${APP_PATH}"

echo "Done: ${DMG_PATH}"
