# ADR-0004 — Zig + Native SDK on the zero-config build

- **Status:** Accepted
- **Date:** 2026-07-11

## Context

Studio needs a toolchain for a native desktop app that can open raw sockets, run
for days, render its own UI, and ship as a single binary. Two sub-decisions:

1. **Language / framework.** The native-rendered UI decision
   ([ADR-0003](0003-native-rendered-ui.md)) points at the Native SDK, whose
   native surface is authored in Zig. Zig also fits the systems-level work Studio
   needs (a WebSocket proxy, streaming parsers over gigabyte traces) with manual
   memory control and no runtime.
2. **Build ownership.** The Native SDK CLI can scaffold either a *zero-config*
   app (the CLI owns the build graph; no `build.zig` in the repo) or an *ejected*
   app (`native eject` writes an owned `build.zig` / `build.zig.zon`). Zero-config
   keeps the repo minimal but cedes build control to the CLI; ejecting grants
   full control at the cost of owning framework-wiring boilerplate.

## Decision

Studio is written in **Zig on the Native SDK**, and stays on the **zero-config
build** until a concrete need forces ejection.

- `app.zon` is the manifest; `src/` holds the app; the `native` CLI (`dev`,
  `test`, `build`, `check`, `doctor`, `package`) owns the build.
- The framework is provided by the pinned `@native-sdk/cli` package, so CI needs
  only Node, Zig, and `npm install -g @native-sdk/cli` — no framework checkout or
  vendoring.
- The OCPP engine is organized so it stays pure Zig and headlessly testable,
  independent of the UI and platform layers, behind a version-tagged protocol
  boundary so OCPP 2.0.1 can be added without reworking 1.6J.

## Consequences

- A minimal repository: no build files to maintain, and upgrades come by bumping
  one pinned CLI version.
- The trade-off is less build control. Custom build steps (extra link inputs, a
  vendored C dependency such as a TLS library for the future secure proxy) are
  not expressible until the app ejects. When that need is real — most likely
  around live-capture TLS — Studio will `native eject` and own its `build.zig` in
  a dedicated ADR-superseding change.
- Pinning the CLI version keeps a pre-1.0 SDK's churn from breaking `main`
  unexpectedly; CI catches breakage on upgrade.
- Zig is itself pre-1.0. The toolchain is pinned to `0.16.0` and upgraded
  deliberately.
