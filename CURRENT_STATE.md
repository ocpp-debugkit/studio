# CURRENT_STATE.md

> Living document — updated inside every PR before merge.

## Current version

`0.0.0` — pre-release foundation (unreleased).

## Active milestone

**S0 — Foundation: complete.** Next up: **S1 — Engine core** (see
[ROADMAP.md](ROADMAP.md)).

## What's done

### S0 — Foundation ✅

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
- **Founding docs & governance** (#7) — README, ROADMAP, CURRENT_STATE, AGENTS,
  CONTRIBUTING, CODE_OF_CONDUCT, SECURITY.
- **Architecture decision records** (#8) — ADR-0001..0004: independent
  implementation, macOS-first platforms, native-rendered UI, Zig zero-config.

**Exit criteria met:** CI green on macOS + Linux; `native doctor --strict` clean.

## What's in progress

- Nothing in flight — S0 is closed; S1 is next.

## What's next

**S1 — Engine core (0.1.0):** the pure-Zig OCPP engine — canonical `Event` /
`Session` / `Failure` types, the parser (JSON object, JSONL, bare array), the
normalizer (direction inference + timestamp normalization), and session
correlation by transaction id. Headless and testable via `native test`.

## Known blockers / decisions pending

- None. Foundational decisions are captured as ADRs.

## Area status

| Area | Status |
| --- | --- |
| `repo` (tooling, CI) | ✅ done for S0 |
| `docs` (docs, ADRs) | ✅ done for S0 |
| `ocpp` (engine) | ⬜ not started (S1) |
| `ui` (native views) | ⬜ placeholder (S3) |
| `capture` (live proxy) | ⬜ not started (S5) |
| `cli` (headless) | ⬜ not started (S4) |
| `conformance` | ⬜ not started (S2) |
