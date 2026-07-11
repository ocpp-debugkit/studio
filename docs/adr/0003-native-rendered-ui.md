# ADR-0003 — Native-rendered UI, no WebView

- **Status:** Accepted
- **Date:** 2026-07-11

## Context

The Native SDK supports two UI architectures that can even coexist in one app:

1. **WebView shell** — render a web frontend (React, Next, Vite, …) inside a
   platform WebView, with a bridge to native Zig. This would let Studio reuse the
   toolkit's existing React inspector components.
2. **Native-rendered** — declarative `.native` markup views driven by a Zig
   `Model` / `Msg` / `update` loop, drawn by the SDK's own engine. No browser, no
   WebView, no web frontend.

The WebView route is the fastest path to a UI because it reuses existing web
code. But it reintroduces exactly what Studio was created to escape: a browser
engine, a JavaScript runtime, web performance ceilings, and a coupling to the
toolkit's frontend. It would make Studio a desktop wrapper around the web app
rather than a distinct native instrument.

## Decision

Studio's UI is **native-rendered**: `.native` markup views plus Zig logic on the
`UiApp` loop, drawn by the SDK engine. **No WebView, no web frontend, and no
reuse of the toolkit's React components** — consistent with the zero-code
relationship in [ADR-0001](0001-independent-implementation.md).

Views stay declarative; all side effects (subprocesses, sockets, filesystem,
clipboard) flow through the update-side effects channel, keeping the UI a pure
function of the model.

## Consequences

- Instant startup, a small binary, low memory, and no GC pauses — the native
  performance that justifies a separate desktop product, and what lets Studio
  handle traces far larger than a browser tab.
- The UI must be built in the SDK's markup + Zig model, not in familiar web
  tech. This is a real learning and authoring cost, and it means respecting the
  engine's per-view budgets (virtualized lists for large event timelines).
- No dependency on a browser engine's release cadence or security surface.
- If a genuine need for embedded web content ever appears (rendering a
  third-party HTML report, say), the SDK's WebView pane can be added for that
  surface specifically — without making the app WebView-based. That would be a
  new ADR.
