//! Aggregate root for the pure-Zig OCPP engine.
//!
//! Everything under `src/ocpp/` is headless and UI-free — it imports no
//! `native_sdk` or `runner` modules, so it builds and tests on every platform
//! (including `-Dplatform=null`). The UI consumes the engine through the Model.

pub const types = @import("types.zig");
pub const normalizer = @import("normalizer.zig");
pub const parser = @import("parser.zig");

test {
    _ = types;
    _ = normalizer;
    _ = parser;
}
