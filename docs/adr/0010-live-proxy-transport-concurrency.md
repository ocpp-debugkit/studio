# ADR-0010 — Live-proxy transport & concurrency

- **Status:** Accepted
- **Date:** 2026-07-12

## Context

The live-capture proxy (#56) sits between a charge point and its CSMS and must,
concurrently and for the life of a session:

- accept the downstream CP connection and dial the upstream CSMS,
- relay every WebSocket frame in **both** directions at once,
- decode a copy of each frame, record it, and run detection.

Two questions had no obvious default in Zig 0.16:

1. **Sockets.** The classic `std.net` is gone; networking moved into the async
   `std.Io` interface (`std.Io.net`), reached through the `io` the runtime and
   the CLI already thread (`init.io`).
2. **Concurrency.** Both pump directions block on reads, so they must make
   progress independently. `std.Io` offers `io.async` (which *permits*
   single-threaded blocking execution) and `io.concurrent` (which *guarantees*
   independent progress).

## Decision

- **Transport: `std.Io.net`, threaded through `io`.** `run` does
  `IpAddress.listen` → `Server.accept` (CP) and `IpAddress.connect` (CSMS), then
  drives the relay over each stream's reader/writer.
- **Concurrency: `io.concurrent`, not `io.async`.** One direction runs
  concurrently and the other inline; when the inline side ends (its peer closed),
  the concurrent one is cancelled so the session tears down cleanly. Two blocking
  pumps under `io.async` could deadlock on a single-threaded backend;
  `io.concurrent` rules that out.
- **Shared state guarded by `std.Io.Mutex`.** Both directions feed one `Sink`
  (event list, sequence counter, recorder, detection). Ingest is serialized with
  an `Io.Mutex` (cooperates with the scheduler on any backend); `detect`/`count`
  are called only when pumping is quiesced.
- **Verbatim relay.** Frames are forwarded byte-for-byte. The masking polarity is
  preserved hop-for-hop (CP→CSMS stays client→server/masked; CSMS→CP stays
  server→client/unmasked), so raw bytes are valid on the second hop; the tap
  decodes a *copy*.
- **A testable seam.** `relayStreams` is generic over `*Io.Reader`/`*Io.Writer`,
  so the whole relay — MITM handshake, concurrent pump, record, detect — is
  driven in-memory under test (with a `std.Io.Threaded` io for real concurrency
  and the `Io.Mutex`), while `run` supplies socket reader/writers. No OS
  socketpair is used: `socketpair(2)` here supports only `AF_INET`, which the OS
  rejects, and no `AF_UNIX` pair is exposed.
- **Wall-clock via `TimeSource`.** Time in 0.16 is read from `io`
  (`Clock.now(.real, io)`), so a plain function can't supply it. A small
  `TimeSource` union provides `fixed` (deterministic, tests), `wall` (the io
  clock, live), or `none`.
- **Deterministic session key.** The upstream handshake key is derived from the
  CP's own key (not a secret — the peer only echoes it), which also lets tests
  reproduce the proxy's key and precompute the matching accept token.

## Consequences

- The relay logic is fully unit-tested in-memory with genuine concurrency; the
  thin socket glue in `run` is compiled (referenced from a test) and exercised
  end-to-end when the `studio capture` CLI wires it (#57).
- No new dependency; `std.Io` covers sockets, concurrency, mutex, and clock.
- Single session per `run` for now (accept one CP, relay, return). A multi-session
  accept loop is a later refinement, behind the same relay core.
- TLS (secure profiles) remains post-0.5, behind the same transport boundary
  (ADR-0008).
