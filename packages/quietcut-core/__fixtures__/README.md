# Verification fixtures

These fixtures support the Phase 1.6 verification gate from `docs/PLAN.md`:
the refactored `quietcut-cli` must produce a functionally-equivalent edit
plan to the legacy CLI in `/Users/jamesqquick/code/local-video-tools/` on
the same input.

## Fixture file (not checked in)

The binary fixture lives outside the repo because it's too large to track
in git. Resolve the path via the env var `SMARTCUT_FIXTURE` or fall back
to the default below.

- Default path: `~/Movies/2026-06-11 11-44-01.mov`
- 74 seconds, 1080p H.264 + AAC, ~57 MB
- Produces a 7-region silence plan with 0 retakes against `claude-opus-4-8`

## Reproducing the gate

From the repo root with both `.env` populated and `pnpm install` done:

```bash
SMARTCUT_FIXTURE="${SMARTCUT_FIXTURE:-$HOME/Movies/2026-06-11 11-44-01.mov}" \
  ./packages/quietcut-core/__fixtures__/verify.sh
```

The script:
1. Runs the legacy CLI under `/Users/jamesqquick/code/local-video-tools/`
   with `-y --dry-run --save-plan` and stores the plan JSON in `/tmp`.
2. Runs the new CLI here with the same args and saves its plan.
3. `diff`s the two plans. Identical plans = pass.

The LLM retake-detection step is non-deterministic, so a *content* diff
only makes sense when both runs see the same audio in the same pass
count. A clip with zero retakes (like the default fixture) makes this
gate strict; for longer clips, compare structural metadata (op counts,
durations) instead.
