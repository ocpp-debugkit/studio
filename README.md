# OCPP DebugKit Studio

[![CI](https://github.com/ocpp-debugkit/studio/actions/workflows/ci.yml/badge.svg)](https://github.com/ocpp-debugkit/studio/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

> A native desktop debugger for OCPP charging sessions — the bench instrument of the OCPP DebugKit ecosystem.

**OCPP DebugKit Studio** is a native desktop application for engineers building and operating OCPP charge points and CSMS backends. Think of it as *Wireshark for OCPP*: sit between a charging station and its backend, decode every frame live, flag protocol failures as they happen, and keep a high-performance offline inspector for the traces you capture.

Studio is built in [Zig](https://ziglang.org) on the [Native SDK](https://github.com/vercel-labs/native) — native-rendered, no browser, no Electron. It starts instantly, stays small, and does the things a browser tab fundamentally cannot: open raw sockets, watch the filesystem, and run for days as a background monitor.

> 🚧 **Early development.** The foundation is in place (a native window, green CI on macOS + Linux, an automation-driven smoke test). The OCPP engine and inspector UI are next — see the [roadmap](ROADMAP.md).

## The ecosystem

Studio is one of two independent products under the OCPP DebugKit umbrella:

| Project | Language | Surface | Role |
| --- | --- | --- | --- |
| [`@ocpp-debugkit/toolkit`](https://github.com/ocpp-debugkit/toolkit) | TypeScript | npm library · CLI · web app | The library and CI brain — parse, analyze, and report OCPP traces anywhere |
| **`ocpp-debugkit/studio`** (this repo) | Zig | native desktop app | The instrument on the bench — live capture, native performance, OS integration |

The two share **no code**. They meet only at a *conformance contract*: the same trace format, the same normalized event model, the same failure taxonomy, and the same scenario fixtures. A trace captured in Studio opens in the toolkit's web inspector, and vice versa — two independent implementations, one format. See [ADR-0001](docs/adr/0001-independent-implementation.md).

## What it will do

The near-term vision, in priority order (full detail in the [roadmap](ROADMAP.md)):

- **Inspect** — open JSON / JSONL / bare-array traces; virtualized timeline, per-message inspector, session correlation, failure list.
- **Detect** — the full OCPP 1.6J failure taxonomy, streaming, as events arrive.
- **Watch** — a live WebSocket proxy between charge point and CSMS, decoding OCPP frames in flight and recording them to the canonical trace format.
- **Prove** — reports, trace diffing, anonymize-on-export, and wall-clock replay.
- **Scale** — stream-parse traces far past what a browser tab can hold.

## Quick start

Studio is a source-first project during early development.

**Prerequisites**

- [Zig](https://ziglang.org/download/) `0.16.0`
- The Native SDK CLI: `npm install -g @native-sdk/cli`

**Build and run**

```sh
git clone https://github.com/ocpp-debugkit/studio.git
cd studio

native dev      # build a Debug binary and run it, with markup hot reload
native test     # run the headless test suite
native build    # produce a ReleaseFast binary in zig-out/bin/
native check    # validate src/*.native markup and app.zon
```

The `native` CLI owns the build — there is no `build.zig` to manage.

## Non-goals

Studio is a debugging instrument, not infrastructure. It is **not**:

- a production CSMS, or billing / fleet management;
- a compliance certification tool (no OCTT claims);
- a cloud service — it is local-first, with no accounts and no telemetry.

## Contributing

Contributions are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md), and point your tooling at [AGENTS.md](AGENTS.md) for a structured overview of the architecture and conventions. [CURRENT_STATE.md](CURRENT_STATE.md) tracks what is built and what is in progress.

## Security

Please report vulnerabilities privately via [GitHub Security Advisories](https://github.com/ocpp-debugkit/studio/security/advisories/new). See [SECURITY.md](SECURITY.md).

## License

[Apache License 2.0](LICENSE) © OCPP DebugKit Contributors
