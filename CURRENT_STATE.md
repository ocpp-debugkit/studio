# CURRENT_STATE.md

> Living document — updated inside every PR before merge.

## Current version

`0.0.0` — pre-release foundation (unreleased).

## Active milestone

**S0 — Foundation** (see [ROADMAP.md](ROADMAP.md)).

## What's done

- **Repository genesis** — Apache-2.0 `LICENSE`, `.gitignore`.
- **Scaffold + identity** (#5) — native-rendered Native SDK skeleton (`app.zon`,
  `src/main.zig`, `src/app.native`, `src/tests.zig`), `NOTICE`, `.editorconfig`;
  bundle id `io.github.ocpp-debugkit.studio`, display name "OCPP DebugKit Studio".
  A window opens; the placeholder counter view stands in until S3.
- **CI + automation smoke test** (#6) — `.github/workflows/ci.yml`: a `verify`
  matrix (macOS + Linux) running doctor / validate / headless null-platform
  tests / strict check, and a Linux Xvfb `smoke` job that drives the running
  app through its automation server and uploads a rendered screenshot.
  `scripts/smoke.sh` is the portable driver.

## What's in progress

- **Founding docs & governance** (this PR) — README, ROADMAP, CURRENT_STATE,
  AGENTS, CONTRIBUTING, CODE_OF_CONDUCT, SECURITY.

## What's next

1. **Architecture decision records** — ADR-0001..0004 capturing the foundational
   decisions (independent implementation, macOS-first, native-rendered, Zig).
2. **Close S0** — verify exit criteria, close the milestone.
3. **S1 — Engine core** — the pure-Zig OCPP types, parser, normalizer, and
   session correlation.

## Known blockers / decisions pending

- None. Foundational decisions are captured (or being captured) as ADRs.

## Area status

| Area | Status |
| --- | --- |
| `repo` (tooling, CI) | ✅ done for S0 |
| `docs` (docs, ADRs) | 🔄 in progress |
| `ocpp` (engine) | ⬜ not started (S1) |
| `ui` (native views) | ⬜ placeholder (S3) |
| `capture` (live proxy) | ⬜ not started (S5) |
| `cli` (headless) | ⬜ not started (S4) |
| `conformance` | ⬜ not started (S2) |
