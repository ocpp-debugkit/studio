# The conformance contract (`contract-v1`)

OCPP DebugKit Studio and the TypeScript [toolkit](https://github.com/ocpp-debugkit/toolkit)
are **two independent implementations** of the same OCPP analysis behavior — one
native (Zig), one for the browser and CI (TypeScript). They share **no code**.
They meet only here: a machine-checked **conformance contract** that guarantees
both produce the same analysis of the same trace.

That is the trust story. A trace captured in Studio opens in the toolkit's web
inspector and vice versa; a failure Studio flags is a failure the toolkit flags.
Two implementations agreeing is a stronger correctness signal than either alone —
and it is enforced in CI on every change, not asserted in prose.

## What the contract covers

- **Trace format.** OCPP-J array messages — `[2, id, action, payload]` (Call),
  `[3, id, payload]` (CallResult), `[4, id, errorCode, errorDescription, details]`
  (CallError) — in any of three containers: a JSON object with an `events` array,
  JSONL (one message per line), or a bare array.
- **Event model.** Each message normalizes to a canonical `Event` (unique id,
  message id, timestamp, direction, message type, action, payload, error fields,
  and the raw array). Direction inference and timestamp normalization (ISO 8601 or
  epoch) are part of the contract. See [ADR-0005](adr/0005-engine-value-representation.md).
- **Session correlation.** Events correlate into `Session`s by `transactionId`,
  with connector- and time-based attribution of un-keyed events.
- **Failure taxonomy.** The full OCPP 1.6J failure model — **16 detection rules**,
  each with a stable `FailureCode`, a fixed severity (**4 critical, 10 warning,
  2 info**), and the same thresholds as the reference (heartbeat 60 s, slow
  response 10 s, ±50 % heartbeat deviation, session bounds, the 5-minute boot
  window). The rules live in [`src/ocpp/detection.zig`](../src/ocpp/detection.zig).
- **Scenarios.** **15 shared scenario traces** exercising the rules end to end,
  each pinned to the exact de-duplicated, sorted `FailureCode` set the reference
  implementation detects.

## How conformance is enforced

The 15 scenarios and their expected failure-code sets are **vendored from the
toolkit — the source of truth — never hand-authored**, so a golden can't drift
from what the reference actually detects. On every change, `native test` runs
Studio's full engine (`parseTrace → buildSessionTimeline → detectFailures`) over
each fixture and asserts its detected code set equals the golden — the same
comparison the toolkit's `evaluateScenario` makes. **15/15 must match; a release
is blocked otherwise.** `studio ci` runs the same check from the command line.

The vendored fixtures, goldens, the harness, and the exact regeneration recipe
live in [`src/ocpp/conformance/`](../src/ocpp/conformance/README.md).

## Freeze & versioning

For the 0.5.0 release the contract is **frozen as `contract-v1`** (OCPP 1.6J):
the vendored fixtures and goldens are pinned, and the harness gates every build
against them. The freeze rationale is recorded in
[ADR-0012](adr/0012-freeze-contract-v1.md).

The contract is **immutable within a version.** A change that alters detected
output — a new or changed rule, a new scenario, a threshold change, or OCPP
2.0.1 — is a **new contract version** (`contract-v2`, …), regenerated against the
matching toolkit release and re-tagged, never an in-place edit of `contract-v1`.
This keeps "two implementations, one format" a checkable claim rather than a hope.

See also [ADR-0001](adr/0001-independent-implementation.md) (independent
implementation + shared contract) and [docs/cli-parity.md](cli-parity.md)
(Studio ⇄ toolkit CLI parity).
