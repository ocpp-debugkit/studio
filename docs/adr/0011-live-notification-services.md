# ADR-0011 — Live-capture notifications via the effects-bound platform services

- **Status:** Accepted
- **Date:** 2026-07-12

## Context

The live notifier (#60) must fire an OS notification when detection raises a
`critical` failure during a live capture (macOS-first, ADR-0002). ADR-0009
recorded the intent — "on a `critical` live failure, call
`services.showNotification`; add `notifications` to `app.zon` permissions" — but
did **not** identify how the notification actually reaches the platform from the
zero-config update loop. This ADR settles that seam.

The obstacle: the effects-capable update is `update_fx(*Model, Msg, *Effects)`.
`Effects` (`runtime/effects.zig`) exposes `spawn` / `fetch` / `writeFile` /
`readFile` / timers / clipboard / window verbs — but **no notification method**.
And `PlatformServices` (which *does* own `showNotification`) is constructed
inside the runner (`app_runner/root.zig` → `runNull` / `runMacos` / …) and never
handed back to `main`. So "just call `services.showNotification`" has no obvious
caller in a zero-config app.

## Finding

`Effects` **binds the platform services as a field**:
`services: ?*const platform.PlatformServices`, set once from the loop thread
before the first dispatch (`runtime/ui_app.zig` binds it; the field's own doc
notes workers reach `services.wake()` through it). Zig has no private fields, so
`update_fx` can read `fx.services` and call
`fx.services.?.showNotification(NotificationOptions{ title, subtitle, body })`.

- **Thread-safe here.** Dispatch (and therefore `update_fx`) runs on the loop
  thread — where platform services are meant to be called. (`wake()` is the one
  entry documented as callable from a worker; calling `showNotification` from the
  *loop thread* is the ordinary case, not the worker case.)
- **Degrades cleanly.** `PlatformServices.showNotification` returns
  `error.UnsupportedService` when the platform provides no notifier. macOS,
  Linux, Windows, and the null platform all provide one; a guarded call swallows
  the error so a notifier-less build is a silent no-op, never a crash.

## Decision

**Fire in-runner through `fx.services`, with the decision logic kept pure.**

- **Decision logic in the model (pure, headless-tested).** `LiveCapture` tracks
  which `critical` failure codes it has already notified this session
  (`std.EnumSet(FailureCode)`). After each live reload, every *new* notifiable
  critical code enqueues one `Notification` (title + body copied into fixed
  buffers — no dependence on the live arena's lifetime). Deduplicated per code per
  session; reset on start. This is what the acceptance test drives — no platform
  involved.
- **Notify on explicit faults only, not prefix-transient criticals.** A live
  session is detected on a *growing prefix*, and two of the critical rules are
  inferred from a message that has not arrived *yet*: `unresponsive_csms` (a Call
  awaiting its CallResult) and `station_offline_during_session` (a
  StartTransaction with no StopTransaction). Both are the normal mid-session
  state — every in-flight request and every open transaction trips them — so
  notifying on them would ping on nearly every session and resolve moments later.
  The notifier fires only on criticals that signal a fault the station
  *explicitly reported*: `connector_fault` (a "Faulted" status) and
  `diagnostics_failure` (a failed upload). The absence-based criticals still
  appear in the live failure panel; they just don't raise an OS notification
  (`Model.isLiveNotifiable`).
- **Firing in `update_fx` (thin).** After `workspace.update`, drain the queue and
  fire each via `fx.services.?.showNotification(...)`, guarded by
  `if (fx.services) |svc|` so tests and the null platform are a no-op.
- **Permission.** Declare `notifications`
  (`native_sdk.security.permission_notifications`) in the app's runtime
  permission set and in `app.zon`. No notification is delivered without it (the
  platform gates on the declared permission plus the OS's own prompt).

## Consequences

- Real OS notifications on critical live failures land **in-runner** — the #33
  runner-eject is not needed. This closes the last S5 issue.
- The split is clean and testable: the **model decides** (pure `EnumSet` dedup,
  covered by headless tests — one notification per critical code, duplicates
  suppressed, non-critical ignored), and **`update_fx` fires** (one guarded
  call). The platform never enters a unit test.
- Reaching `fx.services` uses a **public-but-internal field**, not a dedicated
  effects verb. If a future SDK adds `fx.showNotification` (or a services
  accessor), swap the single call site in `updateFx`. The coupling is isolated
  and documented here so it stays legible.
- This ADR makes concrete — and thereby supersedes — the notification half of
  ADR-0009's decision, which named the API but not the seam.
