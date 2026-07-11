//! Event normalizer — turns raw `TraceEventInput` entries into canonical
//! `Event`s with a classified message type, resolved direction, normalized
//! timestamp, and a stable sequential id.
//!
//! Mirrors the toolkit's `core/normalizer.ts` — the shared conformance
//! contract — including its exact action tables and the 10^12 epoch threshold.

const std = @import("std");
const types = @import("types.zig");

const Direction = types.Direction;
const MessageType = types.MessageType;
const Event = types.Event;
const TraceEventInput = types.TraceEventInput;
const RawMessage = types.RawMessage;

// ---------------------------------------------------------------------------
// Message-field extraction
// ---------------------------------------------------------------------------

/// Classify a raw message by its leading MessageTypeId. An unrecognized id
/// falls back to `.call`, matching the toolkit's default.
pub fn classifyMessageType(message: RawMessage) MessageType {
    if (message == .array and message.array.items.len > 0) {
        const first = message.array.items[0];
        if (first == .integer) {
            if (MessageType.fromTypeId(first.integer)) |mt| return mt;
        }
    }
    return .call;
}

/// The action name of a Call message (index 2). Null for other message types.
pub fn extractAction(message: RawMessage) ?[]const u8 {
    if (message != .array) return null;
    const items = message.array.items;
    if (items.len >= 3 and items[0] == .integer and items[0].integer == 2 and items[2] == .string) {
        return items[2].string;
    }
    return null;
}

/// The payload of any message: Call → index 3, CallResult → index 2,
/// CallError → index 4 (ErrorDetails). `.null` when absent.
pub fn extractPayload(message: RawMessage) std.json.Value {
    if (message != .array) return .null;
    const items = message.array.items;
    if (items.len == 0 or items[0] != .integer) return .null;
    return switch (items[0].integer) {
        2 => if (items.len > 3) items[3] else .null,
        3 => if (items.len > 2) items[2] else .null,
        4 => if (items.len > 4) items[4] else .null,
        else => .null,
    };
}

/// The error code of a CallError message (index 2). Null otherwise.
pub fn extractErrorCode(message: RawMessage) ?[]const u8 {
    if (message != .array) return null;
    const items = message.array.items;
    if (items.len >= 3 and items[0] == .integer and items[0].integer == 4 and items[2] == .string) {
        return items[2].string;
    }
    return null;
}

/// The error description of a CallError message (index 3). Null otherwise.
pub fn extractErrorDescription(message: RawMessage) ?[]const u8 {
    if (message != .array) return null;
    const items = message.array.items;
    if (items.len >= 4 and items[0] == .integer and items[0].integer == 4 and items[3] == .string) {
        return items[3].string;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Direction inference
// ---------------------------------------------------------------------------

/// Actions initiated by the Charge Point (CS → CSMS).
const cs_to_csms_actions = [_][]const u8{
    "BootNotification",
    "Heartbeat",
    "Authorize",
    "StartTransaction",
    "StopTransaction",
    "StatusNotification",
    "MeterValues",
    "DataTransfer",
    "DiagnosticsStatusNotification",
    "FirmwareStatusNotification",
    "SecurityEventNotification",
    "SignCertificate",
    "SignedFirmwareStatusNotification",
    "LogStatusNotification",
};

/// Actions initiated by the CSMS (CSMS → CS).
const csms_to_cs_actions = [_][]const u8{
    "Reset",
    "RemoteStartTransaction",
    "RemoteStopTransaction",
    "GetConfiguration",
    "ChangeConfiguration",
    "SetChargingProfile",
    "ClearChargingProfile",
    "ChangeAvailability",
    "ReserveNow",
    "CancelReservation",
    "DataTransfer",
    "GetLocalListVersion",
    "SendLocalList",
    "TriggerMessage",
    "UnlockConnector",
    "GetDiagnostics",
    "UpdateFirmware",
    "ExtendedTriggerMessage",
    "GetLog",
    "SignedUpdateFirmware",
    "CertificateSigned",
    "DeleteCertificate",
    "GetInstalledCertificateIds",
    "InstallCertificate",
};

fn inList(list: []const []const u8, action: []const u8) bool {
    for (list) |a| {
        if (std.mem.eql(u8, a, action)) return true;
    }
    return false;
}

/// Infer a Call's direction from its action name. `DataTransfer` appears in
/// both tables and resolves to CS→CSMS (checked first), matching the contract.
/// Responses (CallResult/CallError) resolve later, from their matched Call.
pub fn inferDirection(message_type: MessageType, action: ?[]const u8) Direction {
    if (message_type == .call) {
        if (action) |a| {
            if (inList(&cs_to_csms_actions, a)) return .cs_to_csms;
            if (inList(&csms_to_cs_actions, a)) return .csms_to_cs;
        }
    }
    return .unknown;
}

/// A response travels opposite its Call.
pub fn reverseDirection(dir: Direction) Direction {
    return switch (dir) {
        .cs_to_csms => .csms_to_cs,
        .csms_to_cs => .cs_to_csms,
        .unknown => .unknown,
    };
}

// ---------------------------------------------------------------------------
// Timestamp normalization
// ---------------------------------------------------------------------------

/// Values below 10^12 are epoch seconds; at or above, milliseconds.
/// (10^12 ms ≈ year 2001; 10^12 s ≈ year 33658.)
const epoch_ms_threshold: i64 = 1_000_000_000_000;

/// Normalize a timestamp value to epoch milliseconds, or null if missing or
/// unparseable. Accepts ISO 8601 strings (UTC / offset), epoch seconds or
/// milliseconds (as JSON number or numeric string), and null.
pub fn normalizeTimestamp(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |n| scaleIntEpoch(n),
        .float => |f| scaleFloatEpoch(f),
        .number_string, .string => |s| parseTimestampString(s),
        else => null, // null, bool, array, object
    };
}

fn scaleIntEpoch(n: i64) ?i64 {
    if (n >= epoch_ms_threshold) return n;
    // Untrusted input: a large-magnitude "seconds" value must not overflow.
    return std.math.mul(i64, n, 1000) catch null;
}

fn scaleFloatEpoch(f: f64) ?i64 {
    if (!std.math.isFinite(f)) return null;
    const scaled = if (f < @as(f64, epoch_ms_threshold)) f * 1000.0 else f;
    // Untrusted input: guard the float→int cast against out-of-range values.
    if (scaled >= 9.2e18 or scaled <= -9.2e18) return null;
    return @intFromFloat(std.math.round(scaled));
}

fn parseTimestampString(raw: []const u8) ?i64 {
    const s = std.mem.trim(u8, raw, " \t\r\n");
    if (s.len == 0) return null;
    // A stringified epoch is treated as a number first (matching `Number(...)`),
    // and only then as an ISO 8601 datetime.
    if (std.fmt.parseInt(i64, s, 10)) |n| {
        return scaleIntEpoch(n);
    } else |_| {}
    if (std.fmt.parseFloat(f64, s)) |f| {
        return scaleFloatEpoch(f);
    } else |_| {}
    return parseIso8601(s);
}

/// Parse an ISO 8601 / RFC 3339 datetime to epoch milliseconds. Supports
/// `YYYY-MM-DDThh:mm:ss`, an optional `.fff` fraction, and a `Z` or `±hh:mm`
/// zone. A missing zone is treated as UTC (deterministic — a debug tool must
/// not depend on the host's local time). Returns null on any malformation.
fn parseIso8601(s: []const u8) ?i64 {
    if (s.len < 19) return null;
    if (s[4] != '-' or s[7] != '-') return null;
    if (s[10] != 'T' and s[10] != 't' and s[10] != ' ') return null;
    if (s[13] != ':' or s[16] != ':') return null;

    const year = parseDigits(s[0..4]) orelse return null;
    const month = parseDigits(s[5..7]) orelse return null;
    const day = parseDigits(s[8..10]) orelse return null;
    const hour = parseDigits(s[11..13]) orelse return null;
    const minute = parseDigits(s[14..16]) orelse return null;
    const second = parseDigits(s[17..19]) orelse return null;

    if (month < 1 or month > 12) return null;
    if (day < 1 or day > 31) return null;
    if (hour > 23 or minute > 59 or second > 59) return null;

    var idx: usize = 19;

    // Optional fractional seconds → milliseconds (first three digits).
    var millis: i64 = 0;
    if (idx < s.len and s[idx] == '.') {
        idx += 1;
        var digits: usize = 0;
        while (idx < s.len and s[idx] >= '0' and s[idx] <= '9') : (idx += 1) {
            if (digits < 3) {
                millis = millis * 10 + @as(i64, s[idx] - '0');
                digits += 1;
            }
        }
        if (digits == 0) return null; // a lone '.' is malformed
        while (digits < 3) : (digits += 1) millis *= 10;
    }

    // Optional zone.
    var offset_ms: i64 = 0;
    if (idx < s.len) {
        const z = s[idx];
        if (z == 'Z' or z == 'z') {
            // UTC
        } else if (z == '+' or z == '-') {
            if (idx + 3 > s.len) return null;
            const oh = parseDigits(s[idx + 1 .. idx + 3]) orelse return null;
            var om: i64 = 0;
            var j = idx + 3;
            if (j < s.len and s[j] == ':') j += 1;
            if (j + 2 <= s.len) {
                om = parseDigits(s[j .. j + 2]) orelse 0;
            }
            offset_ms = (oh * 60 + om) * 60_000;
            if (z == '-') offset_ms = -offset_ms;
        } else {
            return null;
        }
    }

    const days = daysFromCivil(year, month, day);
    const time_ms = ((hour * 3600) + (minute * 60) + second) * 1000 + millis;
    return days * 86_400_000 + time_ms - offset_ms;
}

fn parseDigits(slice: []const u8) ?i64 {
    var v: i64 = 0;
    for (slice) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + @as(i64, c - '0');
    }
    return v;
}

/// Days since the Unix epoch for a proleptic-Gregorian date
/// (Howard Hinnant's `days_from_civil`).
fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe = y - era * 400; // [0, 399]
    const mp = if (m > 2) m - 3 else m + 9; // [0, 11]
    const doy = @divTrunc(153 * mp + 2, 5) + d - 1; // [0, 365]
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy; // [0, 146096]
    return era * 146097 + doe - 719468;
}

// ---------------------------------------------------------------------------
// normalizeEvents
// ---------------------------------------------------------------------------

/// Normalize raw trace inputs into canonical events. Events keep their input
/// order and get sequential ids (`evt-0001`). Direction resolves in two passes:
/// explicit input direction wins; otherwise Calls infer from their action, and
/// responses inherit the reverse of their matched Call's direction.
///
/// Allocations (the events slice and each id string) come from `allocator` —
/// pass a per-parse arena so the whole result frees at once.
pub fn normalizeEvents(allocator: std.mem.Allocator, inputs: []const TraceEventInput) ![]Event {
    const events = try allocator.alloc(Event, inputs.len);

    for (inputs, 0..) |input, index| {
        const message = input.message;
        const message_type = classifyMessageType(message);
        const action = extractAction(message);

        // Respect an explicit direction (even `unknown`); infer only when absent.
        const direction: Direction = input.direction orelse
            if (message_type == .call) inferDirection(message_type, action) else .unknown;

        events[index] = .{
            .id = try std.fmt.allocPrint(allocator, "evt-{d:0>4}", .{index + 1}),
            .message_id = messageIdOf(message),
            .timestamp = normalizeTimestamp(input.timestamp),
            .direction = direction,
            .message_type = message_type,
            .action = action,
            .payload = extractPayload(message),
            .error_code = extractErrorCode(message),
            .error_description = extractErrorDescription(message),
            .raw_message = message,
        };
    }

    // Second pass: resolve response directions from their matched Call.
    var call_dirs = std.StringHashMap(Direction).init(allocator);
    defer call_dirs.deinit();
    for (events) |e| {
        if (e.message_type == .call and e.direction != .unknown) {
            try call_dirs.put(e.message_id, e.direction);
        }
    }
    for (events) |*e| {
        if (e.direction == .unknown and e.message_type != .call) {
            if (call_dirs.get(e.message_id)) |call_dir| {
                e.direction = reverseDirection(call_dir);
            }
        }
    }

    return events;
}

fn messageIdOf(message: RawMessage) []const u8 {
    if (message == .array and message.array.items.len >= 2 and message.array.items[1] == .string) {
        return message.array.items[1].string;
    }
    return "";
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn parseValue(arena: std.mem.Allocator, json: []const u8) std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch unreachable;
}

test "normalizeTimestamp: ISO 8601 UTC and offset resolve to the same instant" {
    // 2024-01-15T10:00:00Z — verified against the toolkit's Date.parse value.
    const expected: i64 = 1_705_312_800_000;
    try testing.expectEqual(expected, normalizeTimestamp(.{ .string = "2024-01-15T10:00:00.000Z" }).?);
    try testing.expectEqual(expected, normalizeTimestamp(.{ .string = "2024-01-15T12:00:00+02:00" }).?);
    // Fractional seconds and a lower-precision fraction.
    try testing.expectEqual(@as(i64, 1_705_312_800_500), normalizeTimestamp(.{ .string = "2024-01-15T10:00:00.5Z" }).?);
}

test "normalizeTimestamp: epoch seconds vs milliseconds threshold" {
    try testing.expectEqual(@as(i64, 1_705_312_200_000), normalizeTimestamp(.{ .integer = 1_705_312_200 }).?);
    try testing.expectEqual(@as(i64, 1_705_312_200_000), normalizeTimestamp(.{ .integer = 1_705_312_200_000 }).?);
    try testing.expectEqual(@as(i64, 1_705_312_200_000), normalizeTimestamp(.{ .string = "1705312200" }).?);
    try testing.expectEqual(@as(i64, 1_705_312_200_000), normalizeTimestamp(.{ .string = "1705312200000" }).?);
}

test "normalizeTimestamp: missing and invalid values yield null" {
    try testing.expectEqual(@as(?i64, null), normalizeTimestamp(.null));
    try testing.expectEqual(@as(?i64, null), normalizeTimestamp(.{ .string = "" }));
    try testing.expectEqual(@as(?i64, null), normalizeTimestamp(.{ .string = "not a date" }));
    try testing.expectEqual(@as(?i64, null), normalizeTimestamp(.{ .float = std.math.inf(f64) }));
    try testing.expectEqual(@as(?i64, null), normalizeTimestamp(.{ .bool = true }));
    // Untrusted: an absurd magnitude must not overflow/panic.
    try testing.expectEqual(@as(?i64, null), normalizeTimestamp(.{ .float = 1e300 }));
}

test "inferDirection and reverseDirection" {
    try testing.expectEqual(Direction.cs_to_csms, inferDirection(.call, "BootNotification"));
    try testing.expectEqual(Direction.cs_to_csms, inferDirection(.call, "StartTransaction"));
    try testing.expectEqual(Direction.csms_to_cs, inferDirection(.call, "Reset"));
    try testing.expectEqual(Direction.csms_to_cs, inferDirection(.call, "RemoteStartTransaction"));
    try testing.expectEqual(Direction.unknown, inferDirection(.call, "UnknownAction"));
    try testing.expectEqual(Direction.unknown, inferDirection(.call, null));
    try testing.expectEqual(Direction.unknown, inferDirection(.call_result, null));
    // DataTransfer is in both tables; CS→CSMS wins (checked first).
    try testing.expectEqual(Direction.cs_to_csms, inferDirection(.call, "DataTransfer"));

    try testing.expectEqual(Direction.csms_to_cs, reverseDirection(.cs_to_csms));
    try testing.expectEqual(Direction.cs_to_csms, reverseDirection(.csms_to_cs));
    try testing.expectEqual(Direction.unknown, reverseDirection(.unknown));
}

test "message classification and field extraction" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const call = parseValue(arena, "[2,\"m1\",\"BootNotification\",{\"vendor\":\"Test\"}]");
    const result = parseValue(arena, "[3,\"m1\",{\"status\":\"Accepted\"}]");
    const err = parseValue(arena, "[4,\"m1\",\"SecurityError\",\"Cert invalid\",{\"detail\":true}]");

    try testing.expectEqual(MessageType.call, classifyMessageType(call));
    try testing.expectEqual(MessageType.call_result, classifyMessageType(result));
    try testing.expectEqual(MessageType.call_error, classifyMessageType(err));

    try testing.expectEqualStrings("BootNotification", extractAction(call).?);
    try testing.expectEqual(@as(?[]const u8, null), extractAction(result));
    try testing.expectEqual(@as(?[]const u8, null), extractAction(err));

    try testing.expectEqualStrings("Test", extractPayload(call).object.get("vendor").?.string);
    try testing.expectEqualStrings("Accepted", extractPayload(result).object.get("status").?.string);
    try testing.expect(extractPayload(err).object.get("detail").?.bool);

    try testing.expectEqualStrings("SecurityError", extractErrorCode(err).?);
    try testing.expectEqual(@as(?[]const u8, null), extractErrorCode(call));
    try testing.expectEqualStrings("Cert invalid", extractErrorDescription(err).?);
    try testing.expectEqual(@as(?[]const u8, null), extractErrorDescription(call));
}

test "normalizeEvents: sequential ids, inference, and response matching" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const inputs = [_]TraceEventInput{
        .{ .message = parseValue(arena, "[2,\"m1\",\"BootNotification\",{}]") }, // inferred CS→CSMS
        .{ .message = parseValue(arena, "[3,\"m1\",{}]") }, // inherits reverse → CSMS→CS
        .{ .message = parseValue(arena, "[2,\"m2\",\"Heartbeat\",{}]") },
    };

    const events = try normalizeEvents(arena, &inputs);
    try testing.expectEqual(@as(usize, 3), events.len);

    try testing.expectEqualStrings("evt-0001", events[0].id);
    try testing.expectEqualStrings("evt-0002", events[1].id);
    try testing.expectEqualStrings("evt-0003", events[2].id);

    try testing.expectEqual(MessageType.call, events[0].message_type);
    try testing.expectEqualStrings("BootNotification", events[0].action.?);
    try testing.expectEqual(Direction.cs_to_csms, events[0].direction);

    try testing.expectEqual(MessageType.call_result, events[1].message_type);
    try testing.expectEqual(@as(?[]const u8, null), events[1].action);
    try testing.expectEqual(Direction.csms_to_cs, events[1].direction);
}

test "normalizeEvents: unmatched response stays unknown; explicit direction respected" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const inputs = [_]TraceEventInput{
        .{ .message = parseValue(arena, "[3,\"orphan\",{}]") }, // no matching Call
        .{ .direction = .unknown, .message = parseValue(arena, "[2,\"m1\",\"BootNotification\",{}]") },
    };

    const events = try normalizeEvents(arena, &inputs);
    try testing.expectEqual(Direction.unknown, events[0].direction);
    // Explicit `unknown` on a Call is respected (not overwritten by inference).
    try testing.expectEqual(Direction.unknown, events[1].direction);
}

test "normalizeEvents: timestamps, error fields, and raw message preserved" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const inputs = [_]TraceEventInput{
        .{ .timestamp = .{ .string = "2024-01-15T10:00:00.000Z" }, .message = parseValue(arena, "[2,\"m1\",\"BootNotification\",{}]") },
        .{ .message = parseValue(arena, "[2,\"m2\",\"Heartbeat\",{}]") }, // no timestamp
        .{ .message = parseValue(arena, "[4,\"m3\",\"SecurityError\",\"Cert invalid\",{\"detail\":true}]") },
    };

    const events = try normalizeEvents(arena, &inputs);
    try testing.expectEqual(@as(?i64, 1_705_312_800_000), events[0].timestamp);
    try testing.expectEqual(@as(?i64, null), events[1].timestamp);

    try testing.expectEqual(MessageType.call_error, events[2].message_type);
    try testing.expectEqualStrings("SecurityError", events[2].error_code.?);
    try testing.expectEqualStrings("Cert invalid", events[2].error_description.?);
    try testing.expect(events[2].raw_message == .array);
    try testing.expectEqual(@as(usize, 5), events[2].raw_message.array.items.len);
}

test "normalizeEvents: empty input" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const events = try normalizeEvents(arena_state.allocator(), &[_]TraceEventInput{});
    try testing.expectEqual(@as(usize, 0), events.len);
}
