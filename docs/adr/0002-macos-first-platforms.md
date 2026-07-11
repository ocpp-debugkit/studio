# ADR-0002 — macOS-first, Linux in CI, Windows post-1.0

- **Status:** Accepted
- **Date:** 2026-07-11

## Context

Studio targets desktop. The Native SDK supports macOS, Linux, and Windows, but
not equally: macOS is the deepest and most polished surface, Linux and Windows
are exercised in CI, and some niceties (native context menus, menu-bar extras)
are macOS-only today. Studio is also, for now, built by a single maintainer.

Committing every UI decision to three release-grade platforms from day one would
triple the cost of every choice before the product has proven itself. Ignoring
the other platforms entirely would let cross-platform assumptions rot until a
painful port later.

## Decision

**macOS-first, with Linux validated in CI from day one, and Windows deferred
until after 1.0.**

- Develop and polish on macOS.
- Keep Linux building and testing in CI on every change. The pure engine and the
  headless view/model tests run cross-platform (`native test -Dplatform=null`),
  and a Linux Xvfb job drives the running GUI through the automation harness — so
  cross-platform breakage surfaces immediately, not at port time.
- The GPU-surface GUI is macOS-first; the Linux GUI is validated headlessly in CI
  and promoted toward release quality around 1.0.
- Windows is out of scope until after 1.0.

## Consequences

- Fast iteration on the primary platform, without paying a three-platform tax on
  every UI decision.
- Linux can never silently rot: CI compiles and exercises the engine there
  continuously, which matters most for the pure-Zig OCPP engine.
- The CI split is asymmetric by design — full build + GUI smoke on Linux (Xvfb),
  build on macOS, headless tests on both. This is a deliberate consequence of
  where GUI automation is cheapest to run in CI, not a statement that Linux is
  the primary target.
- Windows users have no build until post-1.0. Accepted for now.
- This decision is revisited at 1.0, when Linux is promoted to a first-class
  release target and Windows is reconsidered.
