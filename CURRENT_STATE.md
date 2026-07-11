# CURRENT_STATE.md

> Living document — updated inside every PR before merge.

## Current version

`0.0.0` — pre-release foundation (unreleased).

## Active milestone

**S3 — Inspector UI (0.2.0): in progress.** The engine (S0–S2) is complete; the
native inspector is now being built (see [ROADMAP.md](ROADMAP.md)).

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

**S3 — Inspector UI (0.2.0).** Landed so far:

- **Inspector shell (#27)** — the placeholder counter is replaced by a Zig
  `canvas.Ui` builder view (ADR-0006), a bounded multi-trace workspace `Model` /
  `Msg` / `update` (`src/ui/`), and trace loading from command-line path
  arguments (read unbounded in `main` via `init.io`) plus a built-in sample.
- **Virtualized event timeline (#28)** — a windowed virtual list
  (`ui.virtualList`) in a model-owned `split`: one row per event (severity dot,
  time, direction, message, type), row selection, and a first-cut detail pane.
  The window stays viewport-sized in widget nodes no matter the trace length.

Still ahead in S3: the trusted-ingestion capacity path for 500k-event / 100 MB
traces (#29), the full message inspector + session panel (#30), the failure panel
(#31), and search / filter (#32). Interactive open (native dialog + drag-drop) is
deferred to #33 — it needs an ejected runner (see ADR-0006).

## What's next

After S3: **S4 — Analysis parity+ (0.3.0)** — reports, anonymize, diff,
wall-clock replay, and a headless CLI mode.

## Known blockers / decisions pending

- None. Foundational decisions are captured as ADRs.

## Area status

| Area | Status |
| --- | --- |
| `repo` (tooling, CI) | ✅ done for S0 |
| `docs` (docs, ADRs) | ✅ done for S0 |
| `ocpp` (engine) | ✅ done for S2 |
| `ui` (native views) | 🚧 shell + timeline (S3, #27–#28); panes + search next |
| `capture` (live proxy) | ⬜ not started (S5) |
| `cli` (headless) | ⬜ not started (S4) |
| `conformance` | ✅ done for S2 (15/15, `contract-v1`) |
