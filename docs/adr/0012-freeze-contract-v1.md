# ADR-0012 — Freeze `contract-v1` for the 0.5.0 release

- **Status:** Accepted
- **Date:** 2026-07-12

## Context

Studio's correctness claim rests on the conformance contract (ADR-0001): it and
the TypeScript toolkit are independent implementations that must produce the same
analysis of the same trace, checked by the vendored `contract-v1` fixtures and
goldens under `src/ocpp/conformance/`. Through S2–S5 that harness has gated every
change at **15/15**. For the first public release (0.5.0) the contract needs to
be an explicit, stable baseline — a fixed reference point a user or the toolkit
can rely on — not an implicitly-current snapshot.

## Decision

**Freeze the vendored contract as `contract-v1` (OCPP 1.6J) for 0.5.0.** The
fixtures and goldens are pinned; the conformance harness gates every build
against them, and a release is blocked unless 15/15 match. The public contract is
documented in [CONTRACT.md](../CONTRACT.md); the vendored mechanics and the
regeneration recipe stay in `src/ocpp/conformance/README.md`.

The contract is **immutable within a version.** Any change that alters detected
output — a new or changed detection rule, a new scenario, a threshold change, or
OCPP 2.0.1 — is a **new version** (`contract-v2`, …), regenerated against the
matching toolkit release and re-tagged. `contract-v1` is never edited in place.

## Consequences

- 0.5.0 ships against a named, frozen baseline; "two independent implementations,
  one format" is a checkable, CI-enforced claim, not a hope.
- The freeze is a documentation + policy act, not a code change — the harness and
  goldens already exist; this pins them and states the change rule.
- Evolving the analysis (the O(n) detection rewrite #36, or 2.0.1) does not edit
  `contract-v1`; it introduces a new contract version, keeping every released
  Studio pinned to a reproducible reference.
- This ADR refines the versioning half of ADR-0001 (which established the
  contract and the `contract-vN` scheme) by declaring the v1 freeze; it does not
  supersede it. Graduating the contract to a standalone `spec` repo remains the
  deferred option ADR-0001 described, not adopted here.
