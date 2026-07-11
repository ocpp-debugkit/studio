# ADR-0006 — The inspector is a Zig builder view, not `.native` markup

- **Status:** Accepted
- **Date:** 2026-07-11

## Context

The Native SDK's default and recommended way to author a view is declarative
`.native` markup (`ADR-0003`), with the Model / Msg / update logic in Zig. The
S0 scaffold followed that: `src/app.native` held the placeholder counter view.
Markup buys real advantages — hot reload in dev, `native check` binding
validation against the model contract, and a smaller, parser-free release binary.

S3 builds the inspector, whose centerpiece is the **event timeline** (issue #28).
A trace can hold hundreds of thousands of events, and every canvas view has a
hard budget of **1024 retained widget nodes**. The only primitive that renders a
dataset-scale list within that budget is the **windowed virtual list**
(`ui.virtualWindow` + `ui.virtualList`): the runtime owns the scroll and viewport
math, the model owns the data, and the view builds only the visible window.

Per the native-ui contract, the windowed virtual list is **builder-only**. The
closed markup grammar has no channel for a `for` binding to receive the runtime's
requested index range, so markup can only offer a bounded `<list virtualized>`
that still walks every item on each build — fine for hundreds of rows, not for
the 500 000-event capacity target (M8 / issue #29). Markup and a Zig
`canvas.Ui(Msg)` builder view produce the *identical* widget tree (same
structural ids, same typed handler table); the difference is only which
primitives are reachable.

## Decision

**Author the inspector's main view as a hand-written `canvas.Ui(Msg)` builder
view (`UiApp` `Options.view`), not a `.native` markup file.** `src/app.native` is
removed; `src/ui/inspector.zig` is the view, `src/ui/workspace.zig` the Model /
Msg / update.

## Consequences

- The timeline can use the windowed virtual list from the start, so the view
  scales to dataset-size traces within the node budget — the capability the
  milestone is defined around — instead of being rebuilt later.
- The full builder surface is available uniformly: `ui.split`, `ui.tree`,
  `ui.virtualList`, per-element `ElementOptions`, and dynamic child slices, with
  no "not markup-expressible" gaps to work around.
- The view is tested exactly like a markup view would be — build the tree with
  `canvas.Ui`, assert on widgets, and drive `msgForPointer` / `msgForKeyboard` —
  so headless coverage under `-Dplatform=null` is unchanged (`src/tests.zig`).
- Costs accepted: no markup hot reload for the main view (a data inspector is not
  a design-iteration surface), and the `native check` binding-path check does not
  apply to Zig view reads — model correctness is carried by the headless view
  tests instead. The release binary still needs no markup interpreter.
- Simpler secondary surfaces may still be authored in markup later
  (`CompiledMarkupView`) where the virtual list is not needed; this ADR governs
  the main inspector view, not a blanket ban on markup.
- Trace loading uses command-line path arguments read in `main` via `init.io`
  (unbounded). Interactive open — a native dialog and drag-drop — is deferred
  (issue #33): the zero-config `UiApp` exposes no view/effect path to
  `showOpenDialog` or file-drop routing, so it would require ejecting the build to
  own a custom runner, a standing decision left to its own issue and ADR.
