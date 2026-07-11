# Conformance contract (`contract-v1`)

Studio and the TypeScript toolkit are **independent implementations** of the same
OCPP analysis behavior (ADR-0001). This directory is the machine-checked contract
between them: the shared scenarios and the failure codes each must detect.

- **`fixtures/<name>.json`** — the 15 shared scenario **traces** (the input).
- **`goldens/<name>.json`** — each scenario's expected **de-duplicated, sorted
  `FailureCode` set** (the output to match), as a JSON array of wire codes.
- **`harness.zig`** — runs, under `native test`, the full engine
  (`parseTrace → buildSessionTimeline → detectFailures`) over every fixture and
  asserts its detected code set equals the golden — the same comparison the
  toolkit's `evaluateScenario` makes. A missing or extra code fails the scenario
  by name.

## Generated, not hand-authored

Both the fixtures and the goldens are exported from the toolkit — the source of
truth — so a golden can never drift from what the reference implementation
actually detects. They are regenerated (not edited by hand) from the toolkit's
`scenarios` and `evaluateScenario`:

```js
// run against a built @ocpp-debugkit/toolkit
import { scenarios } from '@ocpp-debugkit/toolkit/scenarios';
import { evaluateScenario } from '@ocpp-debugkit/toolkit';
for (const s of scenarios) {
  const detected = [...new Set(evaluateScenario(s).failures.map((f) => f.code))].sort();
  // fixtures/<s.name>.json  <- JSON.stringify(s.trace)
  // goldens/<s.name>.json   <- JSON.stringify(detected)
}
```

## Why it lives under `src/`

The Native SDK zero-config build (ADR-0004) embeds test data with `@embedFile`,
which resolves within the source module root. Keeping the vendored contract here
lets the harness embed it directly — no runtime file I/O, fully hermetic.

## Versioning

Tagged **`contract-v1`** (OCPP 1.6J). When the contract changes — new rules,
new scenarios, or OCPP 2.0.1 — regenerate against the matching toolkit release
and bump the tag.
