# AGENTS.md

A repository guide for contributors and coding agents. Read this before making
changes; it captures the architecture, conventions, and build system so you can
be productive without rediscovering them.

## Project overview

OCPP DebugKit Studio is a native desktop debugger for OCPP charging sessions,
built in Zig on the Native SDK (native-rendered UI + a Zig `Model` / `Msg` /
`update` loop — no WebView, no web frontend). The inspector view is a hand-written
`canvas.Ui` builder view rather than `.native` markup, because the event timeline
needs the builder-only windowed virtual list (see
`docs/adr/0006-inspector-builder-view.md`). It is a fully independent sibling of
the TypeScript `@ocpp-debugkit/toolkit`; the two share a specification contract,
not code (see `docs/adr/0001-independent-implementation.md`).

## Repository layout

```
studio/
├── app.zon                  # app manifest: identity, window, view, security policy
├── src/
│   ├── main.zig             # app wiring + CLI-arg trace loading (re-exports the TEA types)
│   ├── ui/                  # the inspector: builder view + workspace state
│   │   ├── workspace.zig    #   Model, Msg, update — traces, selection, filter/search state
│   │   ├── inspector.zig    #   canvas.Ui builder view: timeline, inspector, panels, filter (ADR-0006)
│   │   └── ui.zig           #   aggregate root (test discovery)
│   ├── ocpp/                # pure, headless OCPP engine (types, parser, detection, …)
│   │   └── conformance/     # vendored shared-contract fixtures + goldens + harness
│   └── tests.zig            # headless view/model integration tests
├── scripts/smoke.sh         # portable automation smoke test (Xvfb in CI)
├── docs/adr/                # architecture decision records
└── .github/workflows/ci.yml # CI: verify (macOS+Linux) + Linux Xvfb smoke
```

Source grows under `src/ocpp/` (the pure, headless-testable engine), `src/ui/`
(the inspector view + state), and later `src/capture/` (live proxy) and
`src/cli.zig` (headless mode). Keep the engine free of UI and platform
dependencies — `src/ui/` consumes it through the workspace Model.

## Build commands

The `native` CLI owns the build (zero-config — there is no `build.zig`):

```sh
native dev                    # build Debug + run, with markup hot reload
native test                   # run the test suite
native test -Dplatform=null   # headless tests (what CI runs)
native build                  # ReleaseFast binary → zig-out/bin/studio
native check --strict         # validate app.zon (and any .native views)
native doctor --strict        # toolchain / environment health
```

Prerequisites: Zig `0.16.0` and `@native-sdk/cli` (`npm install -g @native-sdk/cli`).

## Architecture principles

- **Engine is pure Zig, UI-free.** Everything under `src/ocpp/` must be testable
  headlessly with `native test`. The UI consumes it through the Model.
- **TEA discipline.** The view is a pure function of the model (`ui/inspector.zig`
  builds the tree; it never mutates state); all side effects (spawn, fetch,
  clipboard, sockets) go through the update-side effects channel.
- **Version-tagged protocol boundary.** The decoder keys off an OCPP version tag
  so 2.0.1 can be added later without reworking 1.6J.
- **Conformance over duplication.** Studio mirrors the toolkit's *behavior* via a
  vendored fixture + golden contract, not its source.

## Conventions

- **Commits:** [Conventional Commits](https://www.conventionalcommits.org) with an
  area scope — `feat(engine):`, `fix(capture):`, `ci:`, `docs:`, `chore:`.
- **Issues before code.** Every PR links a tracking issue (`Closes #N`).
- **Tests ship with code.** No behavior lands without a test for it.
- **One concern per PR.** Code, tests, and docs for a change travel together.
- **Living docs.** Update `CURRENT_STATE.md` (and this file, when architecture
  changes) inside the PR, never after merge.
- **CI is the gate.** `verify` (both OSes) and the Linux smoke job must be green.

## Security constraints

Trace files, pasted content, live socket data, and CLI arguments are **untrusted**.
Validate and bound them: safe parsing, explicit size and event-count limits, no
unbounded recursion, and non-sensitive error messages. Processing is local-first —
Studio never uploads user data. Never commit secrets or real identifiers; user-
loaded traces and runtime-generated reports contain the user's own data and must
never be altered by the tool.

## Pointers

- `README.md` — what Studio is and how to build it.
- `ROADMAP.md` — milestones and versions.
- `CURRENT_STATE.md` — what is built and in progress.
- `CONTRIBUTING.md` — setup and PR process.
- `docs/adr/` — why the project is shaped the way it is.
