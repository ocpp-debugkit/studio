# Changelog

All notable changes to OCPP DebugKit Studio are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). This
project is pre-1.0: while Zig, the Native SDK, and the toolkit conformance
reference are all pre-1.0, minor (0.x) releases may include breaking changes.

## [Unreleased]

## [0.5.1] — 2026-07-12

### Changed

- **macOS** — the packaged app bundle is now named `OCPP DebugKit Studio.app`
  (previously `studio.app`), so its on-disk name matches its display name; the CLI
  binary is unchanged (`studio`). The install docs now cover clearing the
  Gatekeeper quarantine on the ad-hoc build.

## [0.5.0] — 2026-07-12

Studio's first packaged, signed public release, assembled across milestones
S0–S5. Highlights:

### Added

- **Engine** — a pure-Zig, headless OCPP 1.6J engine: canonical event / session /
  failure model, a trace parser (JSON object, JSONL, and bare-array formats with
  untrusted-input limits), timestamp + direction normalization, and
  `transactionId` session correlation.
- **Detection** — the full 16-rule OCPP 1.6J failure taxonomy, conformant with the
  TypeScript toolkit and locked to the `contract-v1` goldens (15/15 scenarios).
- **Inspector** — a native window with a virtualized event timeline (smooth past
  500k events), a message inspector (raw OCPP-J array, normalized fields, a
  bounded payload disclosure tree), a session-correlation panel, a ranked failure
  drawer with remediation steps, and search / filter facets. Traces open from
  command-line paths, with a built-in sample.
- **Analysis** — Markdown and self-contained HTML reports, anonymize-on-export
  (redacts idTag / serials / stationId / identifier, resequences transaction ids,
  and scrubs email / phone / IPv4 patterns), semantic trace diff, and a
  deterministic step-through replay engine with a manual scrub transport.
- **Live capture** — a live WebSocket MITM proxy between a charge point and its
  CSMS (hand-rolled RFC 6455 subset): frames are relayed verbatim, decoded in
  flight into canonical events, run through detection as they stream, and recorded
  to the canonical trace format. Surfaced both in a live inspector timeline and
  from the CLI; **OS notifications** fire on critical live failures.
- **Headless CLI** — the same binary is a scriptable CLI: `inspect`, `report`
  (markdown / html), `diff` (text / json), `anonymize`, `capture`, `ci`, and
  `scenario`.
- **Packaging** — macOS (`.dmg`, ad-hoc signed) and Linux (`.tar.gz`) packages via
  `native package`, published by a tag-triggered release workflow.
- **Conformance contract** — the Studio ⇄ toolkit contract frozen and documented
  as `contract-v1` ([CONTRACT.md](docs/CONTRACT.md)), CI-gated on every change.

### Known limitations

- macOS builds are ad-hoc signed, not notarized (first launch needs
  right-click → Open). Notarization is planned post-0.5.
- Failure detection is capped at 50k events (several rules are O(n²)); larger
  traces stay fully inspectable with detection skipped. The O(n) rewrite is
  tracked upstream.
- TLS (`wss://`) live capture, a menu-bar monitor, and interactive open
  (dialog / drag-drop) are planned for later releases.

[Unreleased]: https://github.com/ocpp-debugkit/studio/compare/v0.5.1...HEAD
[0.5.1]: https://github.com/ocpp-debugkit/studio/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/ocpp-debugkit/studio/releases/tag/v0.5.0
