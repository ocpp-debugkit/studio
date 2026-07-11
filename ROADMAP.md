# Roadmap

Studio is built in milestones, each mapping to a semantic version. Milestones
are tracked as [GitHub milestones](https://github.com/ocpp-debugkit/studio/milestones);
this file is the human-readable summary. Scope may be refined as we learn — the
sequencing rationale (engine before UI, capture after the inspector exists) is
the stable part.

| Milestone | Version | Theme | Status |
| --- | --- | --- | --- |
| **S0** | 0.0.x | Foundation | ✅ Complete |
| **S1** | 0.1.0 | Engine core | ✅ Complete |
| **S2** | 0.1.0 | Detection + conformance | ✅ Complete |
| **S3** | 0.2.0 | Inspector UI | ✅ Complete |
| **S4** | 0.3.0 | Analysis parity+ | Next up |
| **S5** | 0.4.0 | Live capture ⭐ | Planned |
| **S6** | 1.0.0 | 1.0 polish | Planned |

## S0 — Foundation (0.0.x) ✅

Repo, tooling, and CI. A native window that opens, an automation-driven smoke
test, founding docs, and architecture decision records. **Exit criteria met:**
CI green on macOS + Linux; `native doctor --strict` clean.

## S1 — Engine core (0.1.0) ✅

The pure-Zig OCPP engine, headless and testable: canonical `Event` / `Session`
types and the `std.json.Value` value boundary (ADR-0005), a parser for the three
input formats (JSON object, JSONL, bare array) with untrusted-input limits, the
normalizer (message classification, timestamp normalization, and direction
inference), and session correlation by transaction id. **Exit criteria met:** the
vendored `normal-session` fixture parses and correlates end to end; engine tests
run green headlessly (`native test -Dplatform=null`) on macOS + Linux.

## S2 — Detection + conformance (0.1.0) ✅

The full OCPP 1.6J failure taxonomy in Zig — all 16 detection rules — plus the
conformance harness that runs the 15 shared scenario fixtures and checks Studio's
detected failures against locked goldens generated from the toolkit.
**Exit criteria met:** 15/15 scenarios match the `contract-v1` goldens under
`native test`.

## S3 — Inspector UI (0.2.0) ✅

The native inspector: a virtualized event timeline, the per-message inspector
(raw / normalized / payload tree), the session and failure panels, search /
filter, and a multi-trace workspace — handling traces far larger than a browser
tab can hold. Traces open from command-line paths and a built-in sample;
interactive open (native dialog + drag-drop) is deferred to #33 (needs an
ejected runner, ADR-0006).

## S4 — Analysis parity+ (0.3.0)

Reach parity with the toolkit's analysis surface: Markdown / HTML reports,
anonymize-on-export, trace diffing, and replay — with real wall-clock playback
that the offline library cannot offer. A headless CLI mode ships in the same
binary.

## S5 — Live capture ⭐ (0.4.0)

The flagship. A live WebSocket proxy between a charge point and its CSMS,
decoding OCPP frames in flight, running detection as events stream, recording
to the canonical trace format, and surfacing it all in a live timeline — with
OS notifications on critical failures. This is the capability a browser tab
cannot provide, and the reason Studio exists.

## S6 — 1.0 polish (1.0.0)

A signed macOS app and a Linux package, a menu-bar live monitor, a complete
docs set, an automation-driven GUI test suite, and the frozen conformance
contract. Public 1.0 release.

## Beyond 1.0

Sequenced one theme per minor: a message composer / playground, a charge-point
simulator, a CSMS mock, an active scenario runner (running the assertion suite
against live endpoints), TLS proxy support, and — behind the same
version-tagged decoder boundary — OCPP 2.0.1.
