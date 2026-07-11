//! Aggregate root for the native inspector UI. Mirrors `ocpp/ocpp.zig`: it
//! references each UI module so `native test` discovers their tests, and gives
//! the rest of the app one import for the view layer.
//!
//! The UI is the only part of the app that touches `native_sdk` canvas types;
//! it consumes the pure engine (`ocpp/`) through the workspace Model.

pub const workspace = @import("workspace.zig");
pub const inspector = @import("inspector.zig");

test {
    _ = workspace;
    _ = inspector;
}
