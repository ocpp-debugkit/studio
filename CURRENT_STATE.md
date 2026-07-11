# CURRENT_STATE.md

> Living document — updated inside every PR before merge.

## Current version

`0.0.0` — pre-release foundation (unreleased).

## Active milestone

**S2 — Detection + conformance (0.1.0): complete.** Next up: **S3 — Inspector UI**
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

### S2 — Detection + conformance ✅

The full 16-rule OCPP 1.6J failure taxonomy in `src/ocpp/detection.zig`, mirroring
the toolkit's `detection.ts`, plus a harness that locks Studio's output to the
toolkit's:

- **Failure model + foundational rules** (#19) — the `Failure` / `FailureCode` /
  `FailureSeverity` model and rules 1–3.
- **Protocol & transaction rules** (#20) — rules 4–10.
- **Timing & anomaly rules** (#21) — rules 11–16.
- **Conformance harness** (#22) — 15 vendored scenario traces + goldens
  (`src/ocpp/conformance/`, `contract-v1`, generated from the toolkit) and a
  `native test` gate asserting Studio's de-duplicated, sorted `FailureCode` set
  matches each golden.

**Exit criteria met:** 15/15 scenarios match the locked goldens.

## What's in progress

- Nothing in flight — S2 is closed; S3 is next.

## What's next

**S3 — Inspector UI (0.2.0):** the native inspector — open / drag-drop traces, a
virtualized event timeline, the per-message inspector, the failure panel, and
search / filter, handling traces far larger than a browser tab can hold.

## Known blockers / decisions pending

- None. Foundational decisions are captured as ADRs.

## Area status

| Area | Status |
| --- | --- |
| `repo` (tooling, CI) | ✅ done for S0 |
| `docs` (docs, ADRs) | ✅ done for S0 |
| `ocpp` (engine) | ✅ done for S2 |
| `ui` (native views) | ⬜ placeholder (S3) |
| `capture` (live proxy) | ⬜ not started (S5) |
| `cli` (headless) | ⬜ not started (S4) |
| `conformance` | ✅ done for S2 (15/15, `contract-v1`) |
