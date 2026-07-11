# ADR-0005 — Engine value representation & version-tagged decoder boundary

- **Status:** Accepted
- **Date:** 2026-07-11

## Context

The engine must carry arbitrary OCPP payloads. Every action has a different
payload shape — `BootNotification`, `MeterValues`, `StartTransaction`,
`StatusNotification`, and dozens more — and raw messages are heterogeneous
JSON arrays: `[2, uniqueId, action, payload]`, `[3, uniqueId, payload]`,
`[4, uniqueId, errorCode, errorDescription, errorDetails]`. Studio needs a
representation for these values that the parser, normalizer, timeline, and
(later) detection and inspector can all read.

Three options were considered:

1. **`std.json.Value`** — keep the parsed JSON tree and read fields by key or
   index. Dynamically typed.
2. **Per-action typed structs** — a hand-written (or comptime-generated) struct
   per OCPP action, populated via `std.json.parseFromValue`. Statically typed.
3. **Raw bytes with lazy re-parse** — store the message slice and re-parse on
   demand.

Two forces shape the choice. First, the engine mirrors the toolkit's
conformance contract, which validates a message's **structure** and otherwise
treats the payload as opaque `unknown` — it does not model every action as a
type. Second, OCPP 2.0.1 is a planned future target (contract-v2); the decode
path must not bake 1.6J assumptions so deep that 2.0.1 becomes a rewrite.

## Decision

**Represent raw messages and payloads as `std.json.Value` at the engine
boundary, over a single per-parse arena, behind a version-tagged decode seam.**

- The parser validates only structural shape — MessageTypeId ∈ {2, 3, 4},
  a string UniqueId, per-type arity, and the string positions for action /
  error code / error description — then hands back canonical `Event`s whose
  `payload` and `raw_message` are `std.json.Value`. Consumers read fields by
  key or index (`payload.object.get("transactionId")`).
- All parsed data — the JSON tree, event IDs, warning strings, session slices —
  borrows from **one arena per parse**. The caller owns the arena's lifetime and
  frees everything at once. There is no per-field heap ownership.
- Decoding is keyed off an **OCPP version tag** (1.6J today). The canonical
  `Event` / `Session` shape is version-neutral; anything that differs by version
  lives behind the tag. OCPP 2.0.1 arrives as new decode / normalize / detection
  modules selected by the tag, not as edits to the 1.6 path.

## Consequences

- The parser and normalizer stay small: no struct-per-action to write or
  maintain, and payloads of any action — including vendor `DataTransfer` — flow
  through unmodified. This matches the contract's "validate shape, treat payload
  as data" stance, which is what conformance parity requires.
- The arena model makes lifetimes trivial and bulk-frees fast, fitting the
  million-event capacity goal. Retaining the whole JSON tree in the arena is
  acceptable and is bounded by the parser's input-size and event-count limits.
- Field access is dynamically typed, so a wrong key or type surfaces at runtime
  rather than compile time. This is mitigated by focused accessor helpers and,
  from S2, the conformance harness that pins detected output against goldens.
- OCPP 2.0.1 support is additive — a new version tag and its modules — rather
  than surgery on the 1.6 code.
- If a hot path later needs typed decode, `std.json.parseFromValue` can layer
  concrete structs onto specific actions **without** changing this boundary.
