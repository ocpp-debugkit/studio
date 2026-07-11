# ADR-0007 — Trusted vs untrusted trace ingestion, and the detection cap

- **Status:** Accepted
- **Date:** 2026-07-11

## Context

Studio's headline capability over the browser toolkit is capacity: open and
inspect traces far larger than a browser tab can hold (target: 500 000 events /
100 MB). But the S1 parser hard-codes the toolkit's browser-scale caps —
`MAX_INPUT_SIZE_BYTES` (10 MB) and `MAX_EVENT_COUNT` (10 000). Those caps are
correct as an **untrusted-input** defense (a malicious or malformed payload from
a live socket or a paste must not exhaust memory), but wrong for a file the user
deliberately opened from their own disk.

Two forces:

1. **Trust is a property of the source, not the parser.** A command-line path (and
   later a file dialog / drag-drop) is a file the user chose — trusted. Live
   capture bytes (S5) are untrusted. The same parser should apply different caps
   depending on which.
2. **Detection has O(n²) rules.** Several of the 16 detection rules match events
   to each other by scanning (`FAILED_AUTHORIZATION` matches each result against
   every event, `CONNECTOR_FAULT` / `UNEXPECTED_START` scan around each
   transaction, etc.). They mirror the toolkit's algorithms and are fine at
   10 000 events, but at 500 000 a realistic call/result trace would stall the UI
   for minutes on load.

## Decision

**Make the ingestion caps a `Limits` value chosen by the source's trust level,
and bound failure detection to a safe event count.**

- `parser.Limits { max_input_bytes, max_events }`, with two presets:
  `untrusted_limits` (10 MB / 10k — the `parseTrace` default, unchanged) and
  `trusted_limits` (256 MB / 2 000 000 — `parseTraceTrusted`). Parsing and
  validation are otherwise identical; only the caps differ.
- The workspace opens user files with `parseTraceTrusted`. Future untrusted
  sources (S5 live capture) keep `parseTrace`.
- JSONL remains the streaming format: it parses one line at a time, so no
  whole-file JSON tree is ever held — peak memory past the input buffer is the
  arena of retained events, which `max_events` bounds. Bare-array / object formats
  do build one tree; JSONL is the format for the largest traces.
- `detection.max_events_for_detection` (50 000) caps failure analysis. Past it the
  workspace **skips** detection and sets `detection_skipped`; the trace still
  parses, correlates, and is fully inspectable in the timeline, and the UI says
  detection was skipped. `detectFailures` itself does not enforce the cap, so the
  conformance harness and other small-trace callers are unaffected.

## Consequences

- Studio delivers the capacity headline honestly: a 500 000-event / 100 MB trace
  opens, correlates, and is inspectable, with the timeline viewport-bounded in
  widget nodes — all O(n) / O(n·sessions), no O(n²) on the load path.
- The trust boundary is explicit and testable: raising an untrusted-input bound is
  a deliberate, reviewed decision keyed to source, not an accident.
- The detection cap is a **known, surfaced** limitation, not silent: large traces
  show "detection skipped (large trace)" rather than a wrong empty result. Making
  the O(n²) rules O(n) (indexing message-id → event, transaction pairing) so
  detection scales to the full trusted capacity is tracked as a follow-up
  (issue #36), with the `contract-v1` conformance goldens as the safety net that
  the optimization keeps output bit-identical.
- The cap (50 000) is a deliberately conservative worst-case bound; it can rise as
  rules are optimized. It lives as one named constant in `detection.zig`.
