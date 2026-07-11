//! Live OCPP-J frame decode — turns one WebSocket text frame into a canonical
//! engine `Event`.
//!
//! The offline parser infers each event's direction with a two-pass heuristic
//! over the whole trace. Live, the direction is **known from the socket** (which
//! peer sent the frame), so it is set explicitly and `unknown` never arises; the
//! timestamp is the wall-clock receipt time (live frames carry no message-level
//! timestamp of their own).
//!
//! Otherwise this mirrors the offline pipeline exactly — the same schema gate
//! (`parser.validateRawMessage`) and the same normalizer field extraction — so a
//! recorded frame re-parses to the same event offline. That portability is what
//! the recorder (#56) and the shared conformance contract rest on.

const std = @import("std");
const ocpp = @import("../ocpp/ocpp.zig");
const types = ocpp.types;
const parser = ocpp.parser;
const normalizer = ocpp.normalizer;

const Event = types.Event;
const Direction = types.Direction;

/// Largest OCPP-J message a single decode will parse. Frames are already bounded
/// by the WS codec (`ws.max_frame_payload`, 16 MiB); this caps the JSON work
/// independent of the transport and matches the engine's untrusted byte ceiling,
/// so live and offline reject the same oversized messages. An OCPP-J message is
/// small JSON — this is generous.
pub const max_message_bytes: usize = parser.MAX_INPUT_SIZE_BYTES; // 10 MiB

pub const DecodeError = error{
    MessageTooLarge,
    InvalidJson,
    NotOcppJMessage,
    OutOfMemory,
};

/// Decode one OCPP-J text frame into a canonical `Event`.
///
/// - `origin` is the direction the frame travels, known from which peer sent it
///   (a server reading a client frame passes `.cs_to_csms`; a client reading a
///   server frame passes `.csms_to_cs`). Set explicitly, so `unknown` never
///   arises live — an accuracy win over the offline inference.
/// - `received_ms` is the wall-clock receipt time in **epoch milliseconds**.
///   Real wall-clock is always ≥ 10^12, so it survives the offline normalizer's
///   seconds/milliseconds threshold unchanged, keeping recordings portable.
///   `null` is allowed (unknown clock).
/// - `seq` is the session-wide, 1-based sequence number the caller (#56)
///   maintains; it forms the stable `evt-NNNN` id.
///
/// Allocations come from `arena`; the returned event borrows it. A decode error
/// concerns one frame only — the caller records/skips it, never aborting the
/// session.
pub fn decodeEvent(
    arena: std.mem.Allocator,
    text: []const u8,
    origin: Direction,
    received_ms: ?i64,
    seq: usize,
) DecodeError!Event {
    if (text.len > max_message_bytes) return error.MessageTooLarge;

    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };

    // Same structural gate the offline parser applies to every raw message.
    if (parser.validateRawMessage(value) != null) return error.NotOcppJMessage;

    return .{
        .id = try std.fmt.allocPrint(arena, "evt-{d:0>4}", .{seq}),
        .message_id = normalizer.messageIdOf(value),
        .timestamp = received_ms,
        .direction = origin,
        .message_type = normalizer.classifyMessageType(value),
        .action = normalizer.extractAction(value),
        .payload = normalizer.extractPayload(value),
        .error_code = normalizer.extractErrorCode(value),
        .error_description = normalizer.extractErrorDescription(value),
        .raw_message = value,
    };
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

test "decodes a Call with the socket-known direction" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const e = try decodeEvent(
        arena,
        "[2,\"m1\",\"BootNotification\",{\"chargePointVendor\":\"Acme\"}]",
        .cs_to_csms,
        1_705_312_800_000,
        1,
    );
    try testing.expectEqualStrings("evt-0001", e.id);
    try testing.expectEqualStrings("m1", e.message_id);
    try testing.expectEqual(types.MessageType.call, e.message_type);
    try testing.expectEqualStrings("BootNotification", e.action.?);
    try testing.expectEqual(Direction.cs_to_csms, e.direction);
    try testing.expectEqual(@as(?i64, 1_705_312_800_000), e.timestamp);
    try testing.expectEqualStrings("Acme", e.payload.object.get("chargePointVendor").?.string);
}

test "decodes CallResult and CallError with direction from the sender" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const res = try decodeEvent(arena, "[3,\"m1\",{\"status\":\"Accepted\"}]", .csms_to_cs, null, 2);
    try testing.expectEqual(types.MessageType.call_result, res.message_type);
    try testing.expectEqual(@as(?[]const u8, null), res.action);
    try testing.expectEqual(Direction.csms_to_cs, res.direction);
    try testing.expectEqual(@as(?i64, null), res.timestamp);

    const err = try decodeEvent(arena, "[4,\"m2\",\"SecurityError\",\"bad cert\",{}]", .csms_to_cs, null, 3);
    try testing.expectEqual(types.MessageType.call_error, err.message_type);
    try testing.expectEqualStrings("SecurityError", err.error_code.?);
    try testing.expectEqualStrings("bad cert", err.error_description.?);
}

test "direction comes from the socket, not action inference" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // An action absent from both inference tables would normalize to `unknown`
    // offline; live, the socket origin is authoritative.
    const e = try decodeEvent(arena, "[2,\"m3\",\"TotallyCustomAction\",{}]", .cs_to_csms, null, 1);
    try testing.expectEqual(Direction.cs_to_csms, e.direction);
}

test "rejects malformed frames without aborting" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectError(error.InvalidJson, decodeEvent(arena, "{ not json", .cs_to_csms, null, 1));
    try testing.expectError(error.NotOcppJMessage, decodeEvent(arena, "{\"foo\":1}", .cs_to_csms, null, 1));
    try testing.expectError(error.NotOcppJMessage, decodeEvent(arena, "[2]", .cs_to_csms, null, 1));
    try testing.expectError(error.NotOcppJMessage, decodeEvent(arena, "[9,\"m\",\"x\",{}]", .cs_to_csms, null, 1));
}

test "rejects an oversize message before parsing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const big = try testing.allocator.alloc(u8, max_message_bytes + 1);
    defer testing.allocator.free(big);
    @memset(big, ' ');
    try testing.expectError(error.MessageTooLarge, decodeEvent(arena, big, .cs_to_csms, null, 1));
}

test "a decoded event re-parses identically offline (recording portability)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const raw = "[2,\"m1\",\"BootNotification\",{\"chargePointVendor\":\"Acme\"}]";
    const ts: i64 = 1_705_312_800_000;
    const live = try decodeEvent(arena, raw, .cs_to_csms, ts, 1);

    // The recorder (#56) writes the JSONL object form, which carries direction
    // and timestamp explicitly — so the offline parser reproduces the same event.
    const line = try std.fmt.allocPrint(
        arena,
        "{{\"timestamp\":{d},\"direction\":\"{s}\",\"message\":{s}}}",
        .{ ts, live.direction.toWire(), raw },
    );
    const reparsed = try parser.parseTrace(arena, line);
    try testing.expectEqual(@as(usize, 1), reparsed.events.len);
    const offline = reparsed.events[0];

    try testing.expectEqualStrings(live.id, offline.id);
    try testing.expectEqualStrings(live.message_id, offline.message_id);
    try testing.expectEqual(live.message_type, offline.message_type);
    try testing.expectEqualStrings(live.action.?, offline.action.?);
    try testing.expectEqual(live.direction, offline.direction);
    try testing.expectEqual(live.timestamp, offline.timestamp);
    try testing.expectEqualStrings(
        live.payload.object.get("chargePointVendor").?.string,
        offline.payload.object.get("chargePointVendor").?.string,
    );
}
