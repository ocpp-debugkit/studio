# CURRENT_STATE.md

> Living document — updated inside every PR before merge.

## Current version

`0.0.0` — pre-release foundation (unreleased).

## Active milestone

**S5 — Live capture (0.4.0): in progress.** S0–S4 are done — analysis parity, a
headless CLI, and the native inspector. S5 is the flagship: a live WebSocket
proxy between a charge point and its CSMS. First landing is the hardened
RFC 6455 transport codec (#54, ADR-0008); see [ROADMAP.md](ROADMAP.md).

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

### S3 — Inspector UI (0.2.0) ✅

Every issue landed:

- **Inspector shell (#27)** — the placeholder counter is replaced by a Zig
  `canvas.Ui` builder view (ADR-0006), a bounded multi-trace workspace `Model` /
  `Msg` / `update` (`src/ui/`), and trace loading from command-line path
  arguments (read unbounded in `main` via `init.io`) plus a built-in sample.
- **Virtualized event timeline (#28)** — a windowed virtual list
  (`ui.virtualList`) in a model-owned `split`: one row per event (severity dot,
  time, direction, message, type), row selection, and a first-cut detail pane.
  The window stays viewport-sized in widget nodes no matter the trace length.
- **Trusted ingestion + capacity (#29)** — trace files the user opens now parse
  under raised `trusted_limits` (256 MB / 2M events) vs. the browser-scale
  `untrusted_limits` kept for live/pasted data (ADR-0007). A 500k-event trace
  parses, correlates, and stays viewport-bounded in the timeline. Failure
  detection is capped at 50k events (several rules are O(n²)); past it the trace
  is fully inspectable but detection is skipped and the UI says so — the O(n)
  detection rewrite is tracked in #36.
- **Message inspector + session panel (#30)** — selecting a timeline row unpacks
  the event in the detail pane: normalized fields, the session it correlates
  into (transaction id, status, connector, start/stop, event count) with a
  jump-to-first-event control, a model-owned disclosure tree over the payload
  (`ui.tree` + the ARIA keymap, bounded in depth/breadth/node-count for hostile
  input), and the raw OCPP-J array pretty-printed. Jump selects the session's
  first event (highlighting it and driving the panels); the literal timeline
  viewport scroll rides the same runtime-eject as #33.
- **Failure panel (#31)** — a fixed-height drawer under the timeline lists every
  detected failure, ranked critical → warning → info (then by first event), each
  with its severity, code, and description. Selecting one expands its remediation
  steps and affected events (accordion) and jumps to its primary event, so a
  failure and its evidence line up. A clean trace shows a positive
  "no failures detected" state; the status bar carries the severity breakdown.
- **Search & filter (#32)** — a toolbar over the timeline: a free-text search
  field (matching action / unique id / payload, case-insensitive) plus AND-composable
  toggle facets (message type, direction, severity). The filtered index set is
  derived in the build arena and drives the virtual list, so filtering a huge
  trace stays viewport-sized (hidden rows never become widgets); the status bar
  shows the match count and an empty result shows a quiet "no matching events".

Deferred out of S3: interactive open — native dialog + drag-drop (#33) — and the
timeline viewport scroll on jump (session/failure), both of which need an ejected
runner (see ADR-0006). Tracked as follow-ups, not blockers.

### S4 — Analysis parity+ (0.3.0) ✅

Every issue landed:

- **Report generation (#41)** — `src/ocpp/report.zig` renders a trace analysis as
  Markdown and self-contained HTML, mirroring the toolkit's reporter (the same six
  sections: header, session overview, timeline summary, failures, suggested next
  steps, event appendix). All trace-derived text is escaped on both paths (HTML
  entities; Markdown table/line-structural chars) — hardening the untrusted-input
  path beyond the toolkit's HTML-only escaping — and every list section is bounded
  so a dataset-scale trace can't produce an unbounded document. A small
  `src/ocpp/summarizer.zig` (ADR-0003 parity) derives the per-session summaries
  the report consumes.
- **Anonymize-on-export (#42)** — `src/ocpp/anonymize.zig` rewrites a parsed trace
  to shareable JSON: known sensitive keys (idTag / serials / stationId /
  identifier) are replaced, `transactionId`s resequenced, and email / phone / IPv4
  patterns redacted in string values (hand-rolled matchers, since Zig std has no
  regex), emitting pretty JSON. It mirrors the toolkit's code — including its two
  documented quirks (meter values are not transformed; `transactionId` resequences
  per occurrence) — flagged in-code rather than silently diverging.
- **Semantic trace diff (#43)** — `src/ocpp/diff.zig` compares two parsed traces
  (mirroring the toolkit's `diffTraces`): events matched by OCPP UniqueId, with
  field-level diffs (timestamp / direction / action / payload-deep-equal /
  errorCode), added/removed events, a failure-set delta by code, and a
  first-session summary comparison. Includes a recursive JSON deep-equality check
  and a compact-JSON renderer for the changed values.
- **Replay (#44)** — `src/ocpp/replay.zig`, a deterministic, timer-free
  `ReplayEngine` (step / stepBack / jumpTo / getState / reset) at parity with the
  toolkit, plus a manual-scrub **transport** in the timeline pane (First / Prev /
  Next / Last + a position readout) that steps the selection over the visible
  (filtered) events, reusing `select_event`. Real wall-clock auto-play is deferred
  to the runner-eject bucket (#33), since the zero-config runner exposes no timer
  effect (spiked).
- **Headless CLI (#45)** — `src/cli.zig`, a second face in the same binary:
  `inspect` / `report` / `diff` / `anonymize` / `ci` / `scenario`, dispatched in
  `main` before any window opens (no runner eject — the spike confirmed a clean
  `main`-branch). A testable render core (pure `render*(bytes) → bytes`) under a
  thin argv / `init.io` / stdout shell; `conformance/harness.zig` grew a callable
  `runAll` / `runNamed` for `ci` / `scenario`. Parity and the intentional
  differences are documented in [docs/cli-parity.md](docs/cli-parity.md).

## What's next

**S5 — Live capture ⭐ (0.4.0)** — the flagship: a live WebSocket proxy between a
charge point and its CSMS, decoding OCPP frames in flight, running detection as
events stream, recording to the canonical trace format, and surfacing it in a
live timeline with OS notifications on critical failures.

## Known blockers / decisions pending

- None. Foundational decisions are captured as ADRs.

## Area status

| Area | Status |
| --- | --- |
| `repo` (tooling, CI) | ✅ done for S0 |
| `docs` (docs, ADRs) | ✅ done for S0 |
| `ocpp` (engine) | ✅ S2 + ingestion (#29) + reports (#41) + anonymize (#42) + diff (#43) + replay core (#44); O(n) detection pending (#36) |
| `ui` (native views) | ✅ S3 inspector (#27–#32) + replay transport (#44) |
| `capture` (live proxy) | 🔨 S5 in progress: WS transport (#54) + OCPP-J frame decode (#55) |
| `cli` (headless) | ✅ inspect/report/diff/anonymize/ci/scenario (#45) |
| `conformance` | ✅ done for S2 (15/15, `contract-v1`) |
