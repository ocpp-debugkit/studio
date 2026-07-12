# ADR-0009 — Live-capture effects channel

- **Status:** Accepted
- **Date:** 2026-07-12

## Context

The live-capture GUI (#59) must append events to a timeline **as they stream**,
and the notifier (#60) must fire an OS notification when a critical failure is
detected live. Both need something the offline inspector never did: a way to move
data into the TEA loop from *outside* a user interaction — an async source
feeding `Msg`s.

The S4 replay spike (#44) concluded the zero-config runner had "no timer/effect
scheduler" and deferred wall-clock replay to the runner-eject bucket (#33). That
conclusion examined the **plain `update`** path (`fn(*Model, Msg) void`) — which
Studio uses today — and it was **incomplete**. This spike re-examined the runtime
against its source (`runtime/ui_app.zig`, `runtime/effects.zig`,
`platform/types.zig`).

## Finding

**A full effects channel exists in the zero-config runtime — outcome (i).**
`UiApp` supports two update forms, exactly one per app
(`runtime/ui_app.zig` asserts `(update != null) != (update_fx != null)`):

- `update: fn(*Model, Msg) void` — the pure form Studio uses now.
- **`update_fx: fn(*Model, Msg, *Effects) void`** — the effects-capable form. The
  runtime calls it with a live `*Effects` (`update_fx(&model, msg, &self.effects)`).

`Effects` (TEA's Cmd half, `runtime/effects.zig`) exposes:

- **`fx.spawn(SpawnOptions)`** — run a subprocess and **stream its stdout back as
  `Msg`s**. `SpawnOptions{ key: u64, argv, stdin?, output: .lines|.collect,
  max_line_bytes, on_line: ?LineMsgFn, on_exit: ?ExitMsgFn }`. In `.lines` mode
  (the default) each stdout line becomes an `on_line` Msg carrying an
  `EffectLine`; an `EffectExit` Msg ends the stream. Bounded (argv count/bytes,
  stdin, line length) and cancellable via **`fx.cancel(key)`** (exactly one
  `on_exit`, no `on_line` after). Requests that can't run are reported through
  `on_exit` with reason `.rejected` — `spawn` never fails from the caller's view.
- `fx.fetch`, `fx.writeFile`, `fx.readFile`, and an `EffectTimer` (a real timer
  effect).

OS notifications exist as a **platform service**:
`services.showNotification(NotificationOptions{ title, subtitle, body })`, gated
by the `notifications` permission (`security.permission_notifications`, declared
in `app.zon`).

## Decision

**#59 and #60 proceed in-runner — no runner eject.**

- **#59 (live view):** switch the app to `update_fx`. On "start capture",
  `fx.spawn` the app's own binary as `studio capture --listen … --upstream …
  --ndjson` in `.lines` mode; each NDJSON line arrives as an `on_line` Msg, is
  decoded (`capture.decode` / `parser`), and appended to the live timeline;
  `fx.cancel(key)` stops it. This is the plan's "self-spawn worker" (winning idea
  #2): crash-isolated (subprocess), cancellable, and it reuses the exact
  `studio capture` path shipped in #57 — the CLI and GUI share one capture engine.
- **#60 (notifications):** on a `critical` live failure, call
  `services.showNotification`; add `notifications` to `app.zon` permissions
  (macOS-first per ADR-0002).

## Consequences

- The S5 GUI tier is **unblocked in-runner**; the #33 runner-eject is *not* needed
  for live capture. Adopting `update_fx` is an ordinary `create`-options change,
  not an eject.
- **Revisit the S4 deferral.** Because a timer effect (`EffectTimer`) and the
  effects channel exist, wall-clock replay auto-play (#44, parked in #33) is
  feasible in-runner too — worth reopening once the effects update lands. This ADR
  supersedes the effects-related half of the #44 spike's conclusion (that there is
  "no effect scheduler"); the platform-open-dialog / drag-drop parts of #33 are
  untouched and still need investigation.
- **De-risking hand-off:** #59 should begin with a minimal `fx.spawn` smoke (spawn
  a trivial command, assert the `on_line`/`on_exit` Msgs arrive) to confirm the
  wiring before building the full view, and resolve the self-executable path
  (argv[0] / `selfExePath`) for the spawn argv.
- Studio stays a single binary: the GUI drives the same `capture` subcommand a
  user runs by hand.
