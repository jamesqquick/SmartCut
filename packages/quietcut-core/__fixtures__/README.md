# Test fixtures

The `quietcut-server` integration tests run the real pipeline against a
media file. The binary fixture lives outside the repo because it's too
large to track in git.

## Providing a fixture

Resolve the path via the `SMARTCUT_FIXTURE` env var, or fall back to the
default below.

- Default path: `~/Movies/2026-06-11 11-44-01.mov`
- Example clip: 74 seconds, 1080p H.264 + AAC, ~57 MB
- Produces a 7-region silence plan with 0 retakes against `claude-opus-4-8`

```bash
SMARTCUT_FIXTURE="$HOME/Movies/your-clip.mov" \
  pnpm --filter quietcut-server test
```

Tests that need the fixture (and AI Gateway credentials) skip themselves
when those aren't present, so the suite still runs without them.
