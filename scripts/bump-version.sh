#!/usr/bin/env bash
# bump-version.sh — Bump the SmartCut version across all five version strings.
#
# Usage:
#   ./scripts/bump-version.sh <new-version>
#   ./scripts/bump-version.sh 0.2.0
#
# Updates:
#   - app/SmartCut/project.yml         (CFBundleShortVersionString)
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
sed -i '' \
  "s/CFBundleShortVersionString: \"[^\"]*\"/CFBundleShortVersionString: \"${NEW_VERSION}\"/" \
  "$PROJECT_YML"
echo "  updated: app/SmartCut/project.yml"

# --- package.json files ---
PACKAGE_FILES=(
  "${REPO_ROOT}/package.json"
  "${REPO_ROOT}/packages/quietcut-core/package.json"
  "${REPO_ROOT}/packages/quietcut-cli/package.json"
  "${REPO_ROOT}/packages/quietcut-server/package.json"
)

for PKG in "${PACKAGE_FILES[@]}"; do
  sed -i '' \
    "s/\"version\": \"[^\"]*\"/\"version\": \"${NEW_VERSION}\"/" \
    "$PKG"
  echo "  updated: ${PKG#"$REPO_ROOT/"}"
done

echo ""
echo "Version bumped to ${NEW_VERSION}. Next steps:"
echo "  git add -A"
echo "  git commit -m \"chore: bump version to ${NEW_VERSION}\""
echo "  git tag v${NEW_VERSION}"
echo "  git push && git push --tags"
