# ADR-0001 — Independent implementation with a shared conformance contract

- **Status:** Accepted
- **Date:** 2026-07-11

## Context

OCPP DebugKit already exists as `@ocpp-debugkit/toolkit`: a TypeScript library,
CLI, and web app that parse OCPP traces, detect failures, and generate reports —
deliberately offline, and explicitly *not* a CSMS, simulator, or active endpoint
tester. Studio is a native desktop application that claims exactly the live,
system-level territory the toolkit declares out of scope.

The question is how the two relate. Options considered:

1. **Share the toolkit's code** — e.g. wrap the TypeScript engine in a WebView
   shell, or ship it as an embedded runtime. This couples Studio to a JavaScript
   runtime and to the toolkit's release cadence, and undercuts the reason to
   build natively at all.
2. **Reimplement the analysis engine in Zig, sharing nothing.** Two independent
   implementations that risk silently diverging in behavior.
3. **Independent implementations bound by a specification contract.** Studio
   reimplements the engine in Zig but is held to the toolkit's observable
   behavior through shared fixtures and golden outputs.

## Decision

Studio is a **fully independent implementation** written in Zig. It shares **no
code** with the toolkit. The two projects meet only at a **conformance
contract**:

- the trace input formats (JSON object, JSONL, bare array);
- the canonical normalized event model (`Event` / `Session` / `Failure`);
- the failure taxonomy (rule ids, severities, thresholds);
- the scenario fixtures and their expected results.

Conformance is enforced mechanically: a pinned snapshot of the shared scenario
fixtures plus golden detected-failure sets is vendored into `conformance/`, and
CI runs Studio's engine over them and asserts an exact match. The contract is
versioned (`contract-v1`); it may later graduate to its own repository if drift
pressure appears, but not before it needs to.

Where the toolkit's prose documentation and its code disagree, Studio mirrors the
**code** (the observable behavior), not the prose.

## Consequences

- Studio is free to be idiomatic Zig and to exploit native capabilities without
  dragging along a JavaScript runtime or the toolkit's abstractions.
- A trace captured in Studio opens in the toolkit's inspector and vice versa —
  the shared format is a real interoperability guarantee, and a marketing story:
  two independent implementations, one format.
- The cost is a second implementation of the engine, and the discipline of
  keeping goldens current. The conformance harness (milestone S2) is what makes
  that discipline cheap and automatic.
- Behavioral divergence becomes a CI failure, not a silent bug.
