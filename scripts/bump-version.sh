#!/usr/bin/env bash
# bump-version.sh — Bump the SmartCut version across all release version strings.
#
# Usage:
#   ./scripts/bump-version.sh <new-version>
#   ./scripts/bump-version.sh 0.2.0
#
# Updates:
#   - app/SmartCut/project.yml         (CFBundleShortVersionString + CFBundleVersion)
#   - app/SmartCut/SmartCut/Info.plist (CFBundleShortVersionString + CFBundleVersion)
#   - package.json                     (root workspace)
#   - packages/quietcut-core/package.json
#   - packages/quietcut-cli/package.json
#   - packages/quietcut-server/package.json

set -euo pipefail

NEW_VERSION="${1:?Usage: $0 <new-version> (e.g. 0.2.0)}"

# Validate semver format
if ! [[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9._-]+)?$ ]]; then
  echo "error: version must be semver (e.g. 0.2.0 or 0.2.0-beta.1)" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "Bumping version to ${NEW_VERSION}"

# --- project.yml ---
PROJECT_YML="${REPO_ROOT}/app/SmartCut/project.yml"
grep -q 'CFBundleShortVersionString:' "$PROJECT_YML" \
  || { echo "error: CFBundleShortVersionString not found in project.yml" >&2; exit 1; }
sed -i '' \
  "s/CFBundleShortVersionString: \"[^\"]*\"/CFBundleShortVersionString: \"${NEW_VERSION}\"/" \
  "$PROJECT_YML"

# Increment the build number (CFBundleVersion) — Sparkle uses this integer,
# not the marketing version, to determine whether an update is newer.
grep -q 'CFBundleVersion:' "$PROJECT_YML" \
  || { echo "error: CFBundleVersion not found in project.yml" >&2; exit 1; }
CURRENT_BUILD=$(grep 'CFBundleVersion:' "$PROJECT_YML" | grep -oE '"[0-9]+"' | tr -d '"')
NEW_BUILD=$((CURRENT_BUILD + 1))
sed -i '' \
  "s/CFBundleVersion: \"[^\"]*\"/CFBundleVersion: \"${NEW_BUILD}\"/" \
  "$PROJECT_YML"
echo "  updated: app/SmartCut/project.yml (version ${NEW_VERSION}, build ${NEW_BUILD})"

# --- Info.plist ---
INFO_PLIST="${REPO_ROOT}/app/SmartCut/SmartCut/Info.plist"
grep -q '<key>CFBundleShortVersionString</key>' "$INFO_PLIST" \
  || { echo "error: CFBundleShortVersionString not found in Info.plist" >&2; exit 1; }
sed -i '' \
  "/<key>CFBundleShortVersionString<\/key>/{n;s#<string>[^<]*</string>#<string>${NEW_VERSION}</string>#;}" \
  "$INFO_PLIST"

grep -q '<key>CFBundleVersion</key>' "$INFO_PLIST" \
  || { echo "error: CFBundleVersion not found in Info.plist" >&2; exit 1; }
sed -i '' \
  "/<key>CFBundleVersion<\/key>/{n;s#<string>[^<]*</string>#<string>${NEW_BUILD}</string>#;}" \
  "$INFO_PLIST"
echo "  updated: app/SmartCut/SmartCut/Info.plist (version ${NEW_VERSION}, build ${NEW_BUILD})"

# --- package.json files ---
PACKAGE_FILES=(
  "${REPO_ROOT}/package.json"
  "${REPO_ROOT}/packages/quietcut-core/package.json"
  "${REPO_ROOT}/packages/quietcut-cli/package.json"
  "${REPO_ROOT}/packages/quietcut-server/package.json"
)

for PKG in "${PACKAGE_FILES[@]}"; do
  grep -q '"version":' "$PKG" \
    || { echo "error: \"version\" field not found in ${PKG#"$REPO_ROOT/"}" >&2; exit 1; }
  sed -i '' \
    "s/\"version\": \"[^\"]*\"/\"version\": \"${NEW_VERSION}\"/" \
    "$PKG"
  echo "  updated: ${PKG#"$REPO_ROOT/"}"
done

echo ""
echo "Version bumped to ${NEW_VERSION} (build ${NEW_BUILD}). Next steps:"
echo "  git add -A"
echo "  git commit -m \"chore: bump version to ${NEW_VERSION}\""
echo "  git tag v${NEW_VERSION}"
echo "  git push && git push --tags"
