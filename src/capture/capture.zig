//! Aggregate root for the live-capture layer.
//!
//! Like `ocpp/ocpp.zig`, this exists so the root test block pulls the whole
//! subtree into analysis with a single import. Everything here is headless and
//! socket-free at the codec layer; the proxy loop (#56) adds the I/O.

pub const ws = @import("ws.zig");

test {
    _ = ws;
}
