# ADR-0008 — WebSocket transport: a hand-rolled RFC 6455 subset

- **Status:** Accepted
- **Date:** 2026-07-12

## Context

S5 (live capture) makes Studio a WebSocket man-in-the-middle: a **server** to
the downstream charge point and a **client** to the upstream CSMS, decoding
OCPP-J frames in flight. Zig's standard library has no WebSocket implementation,
so we need one. Two options:

1. **Vendor a dependency** (e.g. a community `websocket.zig`).
2. **Hand-roll** a minimal RFC 6455 subset that Studio owns.

Three constraints shape the choice:

- **The build is zero-config (ADR-0004).** Studio has no `build.zig` /
  `build.zig.zon`; the Native SDK drives the build. Adding a third-party
  dependency would mean ejecting to a custom build — a large, standing
  architectural cost for one protocol.
- **This is the rawest untrusted-input surface in Studio.** Bytes arrive from an
  arbitrary peer over a socket. Owning the codec means owning the hardening
  (masking enforcement, size bounds, malformed-frame rejection) rather than
  trusting a dependency's posture.
- **The needed scope is small and well-specified.** A transparent OCPP-J proxy
  needs the RFC 6455 core — opening handshake, base framing, fragmentation,
  control frames — and nothing exotic. The standard library already provides the
  two handshake primitives (`std.crypto.hash.Sha1`, `std.base64`).

## Decision

**Hand-roll a minimal, hardened RFC 6455 subset in `src/capture/ws.zig`.**

- Keep it a **pure codec**: every function operates on byte buffers, no sockets.
  The whole module is unit-testable without a network. Socket I/O and the proxy
  loop live in `proxy.zig` (#56).
- Implement **both handshake halves** (server-accept and client-request) and
  **both masking rules**, since MITM plays both roles.
- **Enforce hardening in the codec itself:** client→server frames MUST be masked
  and server→client MUST NOT (reject violations); bound per-frame and
  reassembled-message sizes and fragment counts; reject reserved bits, unknown
  opcodes, and malformed control frames.

### In scope

Opening handshake (both halves), base framing (all payload-length forms),
fragmentation reassembly, control frames (close / ping / pong).

### Out of scope

- `permessage-deflate` and other extensions.
- **TLS** — the secure-profile (OCPP 2/3) work is post-0.5 and slots behind this
  same codec boundary via a vetted C binding, not `std`.
- Exhaustive protocol edge cases beyond what a transparent OCPP-J proxy needs.

## Consequences

- **No new dependency; the zero-config build (ADR-0004) stays intact.**
- Full control of the untrusted-input hardening at the exact entry point where
  it matters most.
- We own RFC 6455 conformance for the subset we implement — mitigated by keeping
  the scope bounded and testing the codec exhaustively over byte fixtures.
- TLS and compression, if needed, land behind the same `ws.zig` boundary without
  disturbing callers.
- Revisit only if Studio needs extensions (compression) or a breadth of protocol
  edge cases that a maintained library would handle better than a bespoke subset.
