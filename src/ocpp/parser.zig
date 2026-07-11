//! Trace parser — accepts **untrusted** input in JSON object, JSONL, or bare
//! array format and produces normalized `Event`s, with per-entry warnings for
//! malformed data. Mirrors the toolkit's `core/parser.ts` and `schemas.ts`.
//!
//! Security posture (untrusted input):
//! - Input size is capped before parsing (`MAX_INPUT_SIZE_BYTES`).
//! - Event count is capped after parsing (`MAX_EVENT_COUNT`).
//! - JSON is parsed with `std.json` (no prototype/`__proto__` semantics exist in
//!   Zig, so object-key pollution is a non-issue) into a caller-owned arena,
//!   copying every string (`alloc_always`) so the result borrows only the arena.
//! - Malformed *individual* events warn and are skipped; structural failures
//!   abort with an error.

const std = @import("std");
const types = @import("types.zig");
const normalizer = @import("normalizer.zig");

const TraceEventInput = types.TraceEventInput;
const ParseWarning = types.ParseWarning;
const ParseResult = types.ParseResult;
const Direction = types.Direction;

// ---------------------------------------------------------------------------
// Limits
// ---------------------------------------------------------------------------

/// Maximum input size in bytes (10 MB).
pub const MAX_INPUT_SIZE_BYTES: usize = 10 * 1024 * 1024;

/// Maximum number of events after parsing.
pub const MAX_EVENT_COUNT: usize = 10_000;

/// Excerpt of a malformed entry retained in a warning, in bytes.
const RAW_EXCERPT_LEN: usize = 200;

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// Structural parse failures (individual malformed events only warn).
pub const Error = error{
    InputTooLarge,
    EmptyInput,
    TooManyEvents,
    InvalidJson,
    InvalidTraceStructure,
    NoValidEvents,
    OutOfMemory,
};

/// Options passed to every `std.json` parse: copy strings into the arena so the
/// result never borrows from the caller's input buffer.
const json_options: std.json.ParseOptions = .{ .allocate = .alloc_always };

// ---------------------------------------------------------------------------
// Format detection
// ---------------------------------------------------------------------------

const Format = enum { json_object, jsonl, bare_array };

fn detectFormat(trimmed: []const u8) Format {
    return switch (trimmed[0]) {
        '{' => .json_object,
        '[' => .bare_array,
        else => .jsonl,
    };
}

// ---------------------------------------------------------------------------
// Structural validation (mirrors schemas.ts)
// ---------------------------------------------------------------------------

/// Validate a raw OCPP message array. Returns null if valid, else a reason.
fn validateRawMessage(msg: std.json.Value) ?[]const u8 {
    if (msg != .array) return "message must be an array";
    const items = msg.array.items;
    if (items.len < 2) return "message must have at least [MessageTypeId, UniqueId]";
    if (items[0] != .integer) return "MessageTypeId must be a number";
    if (items[1] != .string) return "UniqueId must be a string";
    switch (items[0].integer) {
        2 => {
            if (items.len < 4) return "Call must have at least 4 elements";
            if (items[2] != .string) return "Call Action must be a string";
        },
        3 => {
            if (items.len < 3) return "CallResult must have at least 3 elements";
        },
        4 => {
            if (items.len < 5) return "CallError must have at least 5 elements";
            if (items[2] != .string) return "CallError ErrorCode must be a string";
            if (items[3] != .string) return "CallError ErrorDescription must be a string";
        },
        else => return "MessageTypeId must be 2 (Call), 3 (CallResult), or 4 (CallError)",
    }
    return null;
}

const EventInputResult = union(enum) {
    valid: TraceEventInput,
    invalid: []const u8,
};

/// Validate one trace-event object (mirrors traceEventInputSchema).
fn classifyEventInput(obj: std.json.Value) EventInputResult {
    if (obj != .object) return .{ .invalid = "event must be an object" };

    const message = obj.object.get("message") orelse
        return .{ .invalid = "event is missing the 'message' field" };
    if (validateRawMessage(message)) |reason| return .{ .invalid = reason };

    var timestamp: std.json.Value = .null;
    if (obj.object.get("timestamp")) |ts| switch (ts) {
        .null, .integer, .float, .number_string, .string => timestamp = ts,
        else => return .{ .invalid = "timestamp must be a string, number, or null" },
    };

    var direction: ?Direction = null;
    if (obj.object.get("direction")) |d| {
        if (d != .string) return .{ .invalid = "direction must be a string" };
        direction = Direction.fromWire(d.string) orelse
            return .{ .invalid = "direction must be CS_TO_CSMS, CSMS_TO_CS, or UNKNOWN" };
    }

    return .{ .valid = .{ .timestamp = timestamp, .direction = direction, .message = message } };
}

// ---------------------------------------------------------------------------
// Per-format parsers
// ---------------------------------------------------------------------------

const Events = std.ArrayList(TraceEventInput);
const Warnings = std.ArrayList(ParseWarning);

fn excerpt(arena: std.mem.Allocator, s: []const u8) Error![]const u8 {
    return arena.dupe(u8, s[0..@min(s.len, RAW_EXCERPT_LEN)]);
}

/// JSONL: one event per line. Blank lines are skipped; malformed lines warn.
fn parseJsonl(arena: std.mem.Allocator, input: []const u8, events: *Events, warnings: *Warnings) Error!void {
    var index: usize = 0;
    var it = std.mem.splitScalar(u8, input, '\n');
    while (it.next()) |raw_line| : (index += 1) {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;

        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, line, json_options) catch {
            try warnings.append(arena, .{
                .index = index,
                .message = try std.fmt.allocPrint(arena, "Line {d}: invalid JSON", .{index + 1}),
                .raw_input = try excerpt(arena, line),
            });
            continue;
        };

        switch (classifyEventInput(parsed)) {
            .valid => |ev| try events.append(arena, ev),
            .invalid => |reason| try warnings.append(arena, .{
                .index = index,
                .message = try std.fmt.allocPrint(arena, "Line {d}: {s}", .{ index + 1, reason }),
                .raw_input = try excerpt(arena, line),
            }),
        }
    }
}

/// Bare array: `[[2,"id","Action",{}], ...]`. All-or-nothing — one bad message
/// fails the whole parse (matching bareArraySchema). Timestamp is null.
fn parseBareArray(arena: std.mem.Allocator, input: []const u8, events: *Events, _: *Warnings) Error!void {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, input, json_options) catch
        return error.InvalidJson;
    if (parsed != .array) return error.InvalidTraceStructure;
    if (parsed.array.items.len == 0) return error.InvalidTraceStructure;

    for (parsed.array.items) |msg| {
        if (validateRawMessage(msg) != null) return error.InvalidTraceStructure;
        try events.append(arena, .{ .timestamp = .null, .direction = null, .message = msg });
    }
}

/// JSON object: `{ traceId?, metadata?, events[] }`. Strict — any malformed
/// event fails the whole structure (matching traceSchema). A top-level array is
/// treated as a bare array.
fn parseJsonObject(arena: std.mem.Allocator, input: []const u8, events: *Events, warnings: *Warnings) Error!void {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, input, json_options) catch
        return error.InvalidJson;

    if (parsed == .array) return parseBareArray(arena, input, events, warnings);
    if (parsed != .object) return error.InvalidTraceStructure;

    const events_val = parsed.object.get("events") orelse return error.InvalidTraceStructure;
    if (events_val != .array or events_val.array.items.len == 0) return error.InvalidTraceStructure;

    for (events_val.array.items) |ev| {
        switch (classifyEventInput(ev)) {
            .valid => |input_ev| try events.append(arena, input_ev),
            .invalid => return error.InvalidTraceStructure,
        }
    }
}

// ---------------------------------------------------------------------------
// parseTrace
// ---------------------------------------------------------------------------

/// Parse a trace from a raw string into normalized events plus warnings.
///
/// Allocations come from `arena`; the returned `ParseResult` borrows from it and
/// stays valid until it is freed. The caller owns the arena's lifetime.
pub fn parseTrace(arena: std.mem.Allocator, input: []const u8) Error!ParseResult {
    if (input.len > MAX_INPUT_SIZE_BYTES) return error.InputTooLarge;

    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyInput;

    var events: Events = .empty;
    var warnings: Warnings = .empty;

    switch (detectFormat(trimmed)) {
        .bare_array => try parseBareArray(arena, trimmed, &events, &warnings),
        .jsonl => try parseJsonl(arena, trimmed, &events, &warnings),
        .json_object => parseJsonObject(arena, trimmed, &events, &warnings) catch |e| {
            if (e == error.OutOfMemory) return e;
            // A '{'-leading input may actually be JSONL whose first line is an
            // event object; fall back and keep it only if it yields events.
            var jsonl_events: Events = .empty;
            var jsonl_warnings: Warnings = .empty;
            try parseJsonl(arena, trimmed, &jsonl_events, &jsonl_warnings);
            if (jsonl_events.items.len == 0) return e;
            events = jsonl_events;
            warnings = jsonl_warnings;
        },
    }

    if (events.items.len > MAX_EVENT_COUNT) return error.TooManyEvents;
    if (events.items.len == 0) return error.NoValidEvents;

    return .{
        .events = try normalizer.normalizeEvents(arena, events.items),
        .warnings = try warnings.toOwnedSlice(arena),
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "JSON object: valid trace with and without metadata" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const with_meta =
        \\{"traceId":"test-001","metadata":{"stationId":"CS-001","ocppVersion":"1.6"},
        \\"events":[
        \\{"timestamp":"2024-01-15T10:00:00.000Z","direction":"CS_TO_CSMS","message":[2,"m1","BootNotification",{}]},
        \\{"timestamp":"2024-01-15T10:00:00.500Z","direction":"CSMS_TO_CS","message":[3,"m1",{"status":"Accepted"}]}]}
    ;
    const r1 = try parseTrace(a, with_meta);
    try testing.expectEqual(@as(usize, 2), r1.events.len);
    try testing.expectEqual(@as(usize, 0), r1.warnings.len);
    try testing.expectEqual(types.MessageType.call, r1.events[0].message_type);
    try testing.expectEqualStrings("BootNotification", r1.events[0].action.?);
    try testing.expectEqual(types.MessageType.call_result, r1.events[1].message_type);

    const no_meta =
        \\{"events":[{"message":[2,"m1","BootNotification",{}]},{"message":[3,"m1",{}]}]}
    ;
    const r2 = try parseTrace(a, no_meta);
    try testing.expectEqual(@as(usize, 2), r2.events.len);
}

test "JSON object: structural errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectError(error.InvalidTraceStructure, parseTrace(a, "{\"events\":[]}"));
    try testing.expectError(error.InvalidTraceStructure, parseTrace(a, "{\"traceId\":\"test\"}"));
    try testing.expectError(error.InvalidJson, parseTrace(a, "{ invalid json }"));
    try testing.expectError(error.EmptyInput, parseTrace(a, ""));
    try testing.expectError(error.EmptyInput, parseTrace(a, "   "));
}

test "JSONL: valid, blank lines, and per-line warnings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const valid =
        \\{"timestamp":"2024-01-15T10:00:00.000Z","direction":"CS_TO_CSMS","message":[2,"m1","BootNotification",{}]}
        \\{"timestamp":"2024-01-15T10:00:00.500Z","direction":"CSMS_TO_CS","message":[3,"m1",{"status":"Accepted"}]}
    ;
    const r1 = try parseTrace(a, valid);
    try testing.expectEqual(@as(usize, 2), r1.events.len);
    try testing.expectEqual(@as(usize, 0), r1.warnings.len);

    // Blank lines skipped.
    const blanks = "{\"message\":[2,\"m1\",\"BootNotification\",{}]}\n\n  \n{\"message\":[3,\"m1\",{}]}";
    const r2 = try parseTrace(a, blanks);
    try testing.expectEqual(@as(usize, 2), r2.events.len);

    // Malformed JSON on the second line (index 1).
    const bad_json = "{\"message\":[2,\"m1\",\"BootNotification\",{}]}\n{ bad json\n{\"message\":[3,\"m1\",{}]}";
    const r3 = try parseTrace(a, bad_json);
    try testing.expectEqual(@as(usize, 2), r3.events.len);
    try testing.expectEqual(@as(usize, 1), r3.warnings.len);
    try testing.expectEqual(@as(usize, 1), r3.warnings[0].index);

    // Structurally invalid event (missing message) → warning, not error.
    const bad_struct = "{\"message\":[2,\"m1\",\"BootNotification\",{}]}\n{\"foo\":\"bar\"}";
    const r4 = try parseTrace(a, bad_struct);
    try testing.expectEqual(@as(usize, 1), r4.events.len);
    try testing.expectEqual(@as(usize, 1), r4.warnings.len);
}

test "bare array: parses raw messages; empty array errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const input =
        \\[[2,"m1","BootNotification",{"chargePointVendor":"Test"}],[3,"m1",{"status":"Accepted"}]]
    ;
    const r = try parseTrace(a, input);
    try testing.expectEqual(@as(usize, 2), r.events.len);
    try testing.expectEqual(types.MessageType.call, r.events[0].message_type);
    try testing.expectEqualStrings("BootNotification", r.events[0].action.?);
    try testing.expectEqual(@as(?i64, null), r.events[0].timestamp);

    try testing.expectError(error.InvalidTraceStructure, parseTrace(a, "[]"));
}

test "normalization is applied through parseTrace" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Timestamp normalization variants.
    const ts = try parseTrace(a,
        \\{"events":[
        \\{"timestamp":"2024-01-15T10:00:00.000Z","message":[2,"m1","BootNotification",{}]},
        \\{"timestamp":1705312200,"message":[2,"m2","Heartbeat",{}]},
        \\{"timestamp":1705312200000,"message":[2,"m3","Heartbeat",{}]},
        \\{"timestamp":"not a date","message":[2,"m4","Heartbeat",{}]},
        \\{"message":[2,"m5","Heartbeat",{}]}]}
    );
    try testing.expectEqual(@as(?i64, 1_705_312_800_000), ts.events[0].timestamp);
    try testing.expectEqual(@as(?i64, 1_705_312_200_000), ts.events[1].timestamp);
    try testing.expectEqual(@as(?i64, 1_705_312_200_000), ts.events[2].timestamp);
    try testing.expectEqual(@as(?i64, null), ts.events[3].timestamp);
    try testing.expectEqual(@as(?i64, null), ts.events[4].timestamp);

    // Direction inference + response matching + sequential ids.
    const dir = try parseTrace(a,
        \\{"events":[
        \\{"message":[2,"m1","BootNotification",{}]},
        \\{"message":[3,"m1",{"status":"Accepted"}]},
        \\{"message":[2,"m2","Reset",{}]}]}
    );
    try testing.expectEqualStrings("evt-0001", dir.events[0].id);
    try testing.expectEqualStrings("evt-0003", dir.events[2].id);
    try testing.expectEqual(Direction.cs_to_csms, dir.events[0].direction);
    try testing.expectEqual(Direction.csms_to_cs, dir.events[1].direction);
    try testing.expectEqual(Direction.csms_to_cs, dir.events[2].direction);

    // Error fields + action null for CallResult.
    const err = try parseTrace(a,
        \\{"events":[{"message":[4,"m1","SecurityError","Certificate invalid",{}]},{"message":[3,"m2",{}]}]}
    );
    try testing.expectEqual(types.MessageType.call_error, err.events[0].message_type);
    try testing.expectEqualStrings("SecurityError", err.events[0].error_code.?);
    try testing.expectEqualStrings("Certificate invalid", err.events[0].error_description.?);
    try testing.expectEqual(@as(?[]const u8, null), err.events[1].action);
}

test "events are never reordered" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const r = try parseTrace(a,
        \\{"events":[
        \\{"timestamp":"2024-01-15T10:01:00.000Z","message":[2,"m2","Heartbeat",{}]},
        \\{"timestamp":"2024-01-15T10:00:00.000Z","message":[2,"m1","BootNotification",{}]}]}
    );
    try testing.expectEqualStrings("m2", r.events[0].message_id);
    try testing.expectEqualStrings("m1", r.events[1].message_id);
    try testing.expect(r.events[0].timestamp.? > r.events[1].timestamp.?);
}

test "untrusted input: size and event-count limits" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Size limit: checked before any parsing.
    const huge = try testing.allocator.alloc(u8, MAX_INPUT_SIZE_BYTES + 1);
    defer testing.allocator.free(huge);
    @memset(huge, 'x');
    try testing.expectError(error.InputTooLarge, parseTrace(a, huge));

    // Event-count limit: MAX_EVENT_COUNT + 1 events.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try buf.appendSlice(testing.allocator, "{\"events\":[");
    var i: usize = 0;
    while (i < MAX_EVENT_COUNT + 1) : (i += 1) {
        if (i > 0) try buf.append(testing.allocator, ',');
        try buf.appendSlice(testing.allocator, "{\"message\":[2,\"m\",\"Heartbeat\",{}]}");
    }
    try buf.appendSlice(testing.allocator, "]}");
    try testing.expectError(error.TooManyEvents, parseTrace(a, buf.items));
}

test "untrusted input: object-key pollution is inert" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `__proto__` is just a string key in Zig — no prototype to pollute.
    const r = try parseTrace(a,
        \\{"events":[{"message":[2,"m1","BootNotification",{}]}],"__proto__":{"polluted":true}}
    );
    try testing.expectEqual(@as(usize, 1), r.events.len);
}
