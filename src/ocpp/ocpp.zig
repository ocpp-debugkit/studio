//! Aggregate root for the pure-Zig OCPP engine.
//!
//! Everything under `src/ocpp/` is headless and UI-free — it imports no
//! `native_sdk` or `runner` modules, so it builds and tests on every platform
//! (including `-Dplatform=null`). The UI consumes the engine through the Model.

pub const types = @import("types.zig");

test {
    _ = types;
}
