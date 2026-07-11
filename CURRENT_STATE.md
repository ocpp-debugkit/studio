# CURRENT_STATE.md

> Living document — updated inside every PR before merge.

## Current version

`0.0.0` — pre-release foundation (unreleased).

## Active milestone

**S1 — Engine core (0.1.0): complete.** Next up: **S2 — Detection + conformance**
(see [ROADMAP.md](ROADMAP.md)).

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

### S1 — Engine core ✅

The pure-Zig, headless OCPP engine under `src/ocpp/`, mirroring the toolkit's
conformance contract (behavior, not source) and tested via
`native test -Dplatform=null`:

- **Types & value boundary** (#11) — canonical `Event` / `Session` / trace /
  parse-result types, the `Direction` / `MessageType` / `Status` enums, and the
  `std.json.Value` payload boundary (ADR-0005).
- **Event normalizer** (#12) — message classification, ISO 8601 / epoch
  timestamp normalization, and two-pass direction inference.
- **Trace parser** (#13) — JSON object / JSONL / bare-array formats, structural
  validation, per-entry warnings, and untrusted-input limits (10 MB, 10 000
  events), into a caller-owned arena.
- **Session timeline** (#14) — transactionId correlation, connector / time-based
  distribution of un-keyed events, and session status.

**Exit criteria met:** the vendored `normal-session` fixture parses and
correlates end to end (one completed session, transactionId 100001); engine
tests green headlessly on macOS + Linux.

## What's in progress

- Nothing in flight — S1 is closed; S2 is next.

## What's next

**S2 — Detection + conformance (0.1.0):** the full OCPP 1.6J failure taxonomy in
Zig, plus the conformance harness that runs the shared scenario fixtures and
checks Studio's detected failures against locked goldens.

## Known blockers / decisions pending

- None. Foundational decisions are captured as ADRs.

## Area status

| Area | Status |
| --- | --- |
| `repo` (tooling, CI) | ✅ done for S0 |
| `docs` (docs, ADRs) | ✅ done for S0 |
| `ocpp` (engine) | ✅ done for S1 |
| `ui` (native views) | ⬜ placeholder (S3) |
| `capture` (live proxy) | ⬜ not started (S5) |
| `cli` (headless) | ⬜ not started (S4) |
| `conformance` | ⬜ not started (S2) |
