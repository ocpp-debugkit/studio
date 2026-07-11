# Contributing to OCPP DebugKit Studio

Thanks for your interest in contributing. Studio is an open-source project and
contributions of all kinds are welcome — code, tests, docs, bug reports, and
scenario ideas.

## Prerequisites

- [Zig](https://ziglang.org/download/) `0.16.0`
- The Native SDK CLI: `npm install -g @native-sdk/cli`

Verify your environment:

```sh
native doctor --strict
```

## Getting started

```sh
git clone https://github.com/ocpp-debugkit/studio.git
cd studio
native test      # should pass
native dev       # opens the app
```

The `native` CLI owns the build — there is no `build.zig`. Edit `src/app.native`
while `native dev` runs and the window hot-reloads.

## Development workflow

Studio follows a milestone-driven, issue-first workflow:

1. **Find or open an issue.** Every change starts with a tracking issue describing
   scope and acceptance criteria. Comment to claim it.
2. **Branch** from `main`: `feat/…`, `fix/…`, `docs/…`, `chore/…`, `ci/…`.
3. **Implement** with tests. Keep the change to one concern.
4. **Update living docs** (`CURRENT_STATE.md`, and `AGENTS.md` if architecture
   changed) in the same branch.
5. **Open a PR** that links the issue (`Closes #N`). Fill in what changed and how
   you tested it.
6. CI must be green before merge.

## Conventions

- **Commits:** [Conventional Commits](https://www.conventionalcommits.org) with an
  area scope, e.g. `feat(engine): parse JSONL traces`, `fix(ui): …`, `docs: …`,
  `ci: …`, `chore: …`.
- **Tests ship with code.** No behavior merges without a test. Prefer headless
  tests (`native test -Dplatform=null`) so they run on every platform.
- **One concern per PR.** Code, tests, and docs for a change travel together;
  unrelated cleanups go in their own PR.
- **Style.** Match the surrounding code. `.editorconfig` sets indentation
  (4-space Zig, 2-space markup / YAML / JSON / Markdown).

## Validating your change

```sh
native test -Dplatform=null   # headless tests
native check --strict         # markup + manifest
native doctor --strict        # environment
./scripts/smoke.sh            # drive the running app (builds with -Dautomation=true first)
```

## Security

Treat all trace files, pasted content, socket data, and CLI arguments as
untrusted: validate input, bound sizes, and never expose internal paths in error
messages. Report vulnerabilities privately — see [SECURITY.md](SECURITY.md).
Never commit secrets or real identifiers.

## AI-Assisted Development

Maintainers may use AI-assisted development tools, but all contributions must be
reviewed, tested, documented, and scoped like normal engineering work.
AI-generated code is held to the same standards as any other contribution: it
must pass CI, include tests, be security-reviewed, and be understandable by a
human reviewer.

Contributors using AI agents can point them at [AGENTS.md](AGENTS.md) for a
structured overview of this repository's architecture, conventions, and build
system. [CURRENT_STATE.md](CURRENT_STATE.md) reflects what has been built so far
and what is in progress — use it to orient your agent before starting work.

No AI tool preference is assumed or required. The project does not endorse any
specific AI tool.

## Code of Conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). By
participating, you agree to uphold it.
