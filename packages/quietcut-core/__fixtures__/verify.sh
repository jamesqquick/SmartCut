#!/usr/bin/env bash
# Phase 1.6 verification gate. See README.md alongside this script.
#
# Runs the legacy CLI and the new CLI on the same fixture mp4/mov and
# diffs the resulting EditPlan JSON. Identical = pass.

set -euo pipefail

FIXTURE="${SMARTCUT_FIXTURE:-$HOME/Movies/2026-06-11 11-44-01.mov}"
LEGACY_DIR="${SMARTCUT_LEGACY_DIR:-$HOME/code/local-video-tools}"
NEW_DIR="${SMARTCUT_NEW_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"

if [[ ! -f "$FIXTURE" ]]; then
  echo "fixture not found: $FIXTURE" >&2
  exit 2
fi

LEGACY_PLAN="$(mktemp -t smartcut-legacy-plan-XXXXXX).json"
NEW_PLAN="$(mktemp -t smartcut-new-plan-XXXXXX).json"
trap 'rm -f "$LEGACY_PLAN" "$NEW_PLAN"' EXIT

echo "--- legacy CLI ---"
( cd "$LEGACY_DIR" && pnpm --filter quietcut dev smartcut \
    "$FIXTURE" -y --dry-run --save-plan "$LEGACY_PLAN" )

echo
echo "--- new CLI ---"
( cd "$NEW_DIR" && pnpm --filter quietcut-cli dev smartcut \
    "$FIXTURE" -y --dry-run --save-plan "$NEW_PLAN" )

echo
if diff -u "$LEGACY_PLAN" "$NEW_PLAN"; then
  echo
  echo "PASS: plans are bit-identical."
else
  echo
  echo "FAIL: plans differ. See diff above." >&2
  exit 1
fi
