# CURRENT_STATE.md

> Living document — updated inside every PR before merge.

## Current version

`0.0.0` — pre-release foundation (unreleased).

## Active milestone

**S1 — Engine core (0.1.0): in progress.** S0 — Foundation is complete (see
[ROADMAP.md](ROADMAP.md)).

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

## What's in progress

**S1 — Engine core (0.1.0).** Building the pure-Zig engine module by module:

- **Engine types & value boundary** (#11) — the `src/ocpp/` foundation: canonical
  `Event` / `Session` / trace / parse-result types, the `Direction` /
  `MessageType` / `Status` enums, and the `std.json.Value` payload boundary
  (ADR-0005). Headless, imports no UI/runtime modules, tested via
  `native test -Dplatform=null`.
- **Event normalizer** (#12) — message classification, ISO 8601 / epoch-second /
  epoch-millisecond timestamp normalization, and two-pass direction inference
  (the CS↔CSMS action tables), producing canonical `Event`s. The toolkit's
  normalizer test cases are ported.
- **Trace parser** (#13) — JSON object / JSONL / bare-array formats with format
  detection, structural validation, per-entry warnings for malformed data, and
  the untrusted-input limits (10 MB input, 10 000 events). Parses into a
  caller-owned arena. The toolkit's parser test cases are ported.
- Next: session timeline (#14).

## What's next

**S2 — Detection + conformance (0.1.0):** the full OCPP 1.6J failure taxonomy in
Zig, plus the conformance harness that runs the shared scenario fixtures and
checks Studio's detected failures against locked goldens.

## Known blockers / decisions pending

- None. Foundational decisions are captured as ADRs.

## Area status

| Area | Status |
| --- | --- |
| `repo` (tooling, CI) | ✅ done for S0 |
| `docs` (docs, ADRs) | ✅ done for S0 |
| `ocpp` (engine) | 🚧 in progress (S1) |
| `ui` (native views) | ⬜ placeholder (S3) |
| `capture` (live proxy) | ⬜ not started (S5) |
| `cli` (headless) | ⬜ not started (S4) |
| `conformance` | ⬜ not started (S2) |
