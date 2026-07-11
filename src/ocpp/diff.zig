//! Trace diffing — compare two parsed traces and surface their differences.
//!
//! Mirrors the toolkit's `core/diff.ts`: match events by OCPP UniqueId
//! (`message_id`), compare `timestamp` / `direction` / `action` / `payload`
//! (deep) / `error_code`, diff detected failures by code, and compare the first
//! session's summary. Pure and headless; the result borrows from the input
//! traces' arena and from `gpa`.

const std = @import("std");
const types = @import("types.zig");
const timeline = @import("timeline.zig");
const detection = @import("detection.zig");
const summarizer = @import("summarizer.zig");

const Allocator = std.mem.Allocator;
const Buf = std.ArrayList(u8);

/// The event field a diff is about.
pub const DiffField = enum { timestamp, direction, action, payload, error_code };

/// A field-level difference between two events that share a `message_id`.
/// `value_a` / `value_b` are rendered for display (Zig has no `unknown`): the
/// diff is a reporting artifact, so each differing value is rendered to a string
/// (numbers/enums directly; payloads as compact JSON).
pub const EventDiff = struct {
    message_id: []const u8,
    field: DiffField,
    value_a: []const u8,
    value_b: []const u8,
};

/// First-session summary comparison plus human-readable difference lines.
pub const SummaryDiff = struct {
    a: ?types.SessionSummary,
    b: ?types.SessionSummary,
    differences: []const []const u8,
};

/// The complete diff between two traces. Mirrors the toolkit's `TraceDiff`.
pub const TraceDiff = struct {
    only_in_a: []const types.Event,
    only_in_b: []const types.Event,
    modified: []const EventDiff,
    failures_only_in_a: []const types.Failure,
    failures_only_in_b: []const types.Failure,
    summary_diff: SummaryDiff,
};

// ---------------------------------------------------------------------------
// diffTraces
// ---------------------------------------------------------------------------

/// Compare two parsed traces and return a structured diff.
pub fn diffTraces(gpa: Allocator, a: types.ParseResult, b: types.ParseResult) !TraceDiff {
    // messageId membership sets.
    var set_a = std.StringHashMap(void).init(gpa);
    defer set_a.deinit();
    var set_b = std.StringHashMap(void).init(gpa);
    defer set_b.deinit();
    for (a.events) |e| try set_a.put(e.message_id, {});
    for (b.events) |e| try set_b.put(e.message_id, {});

    // Events present in only one trace (by messageId).
    var only_a: std.ArrayList(types.Event) = .empty;
    for (a.events) |e| if (!set_b.contains(e.message_id)) try only_a.append(gpa, e);
    var only_b: std.ArrayList(types.Event) = .empty;
    for (b.events) |e| if (!set_a.contains(e.message_id)) try only_b.append(gpa, e);

    // Shared messageIds compared positionally. Group B's shared events by id,
    // then walk A in document order (deterministic) matching the k-th A
    // occurrence to the k-th B occurrence — the toolkit's per-id comparison.
    var map_b = std.StringHashMap(std.ArrayList(types.Event)).init(gpa);
    defer map_b.deinit();
    for (b.events) |e| {
        if (!set_a.contains(e.message_id)) continue;
        const g = try map_b.getOrPut(e.message_id);
        if (!g.found_existing) g.value_ptr.* = .empty;
        try g.value_ptr.append(gpa, e);
    }

    var modified: std.ArrayList(EventDiff) = .empty;
    var seen = std.StringHashMap(usize).init(gpa);
    defer seen.deinit();
    for (a.events) |ea| {
        if (!set_b.contains(ea.message_id)) continue;
        const bl = map_b.get(ea.message_id) orelse continue;
        const occ = seen.get(ea.message_id) orelse 0;
        if (occ < bl.items.len) try compareEvents(gpa, ea.message_id, ea, bl.items[occ], &modified);
        try seen.put(ea.message_id, occ + 1);
    }

    // Failure diffing (by code).
    const sessions_a = try timeline.buildSessionTimeline(gpa, a.events);
    const sessions_b = try timeline.buildSessionTimeline(gpa, b.events);
    const failures_a = try detection.detectFailures(gpa, a.events, sessions_a);
    const failures_b = try detection.detectFailures(gpa, b.events, sessions_b);

    var codes_a = std.StringHashMap(void).init(gpa);
    defer codes_a.deinit();
    var codes_b = std.StringHashMap(void).init(gpa);
    defer codes_b.deinit();
    for (failures_a) |f| try codes_a.put(f.code.toWire(), {});
    for (failures_b) |f| try codes_b.put(f.code.toWire(), {});

    var fonly_a: std.ArrayList(types.Failure) = .empty;
    for (failures_a) |f| if (!codes_b.contains(f.code.toWire())) try fonly_a.append(gpa, f);
    var fonly_b: std.ArrayList(types.Failure) = .empty;
    for (failures_b) |f| if (!codes_a.contains(f.code.toWire())) try fonly_b.append(gpa, f);

    // Summary diffing — first session only, mirroring the toolkit.
    const summaries_a = try summarizer.summarizeSessions(gpa, sessions_a, failures_a);
    const summaries_b = try summarizer.summarizeSessions(gpa, sessions_b, failures_b);
    const sum_a: ?types.SessionSummary = if (summaries_a.len > 0) summaries_a[0] else null;
    const sum_b: ?types.SessionSummary = if (summaries_b.len > 0) summaries_b[0] else null;

    return .{
        .only_in_a = try only_a.toOwnedSlice(gpa),
        .only_in_b = try only_b.toOwnedSlice(gpa),
        .modified = try modified.toOwnedSlice(gpa),
        .failures_only_in_a = try fonly_a.toOwnedSlice(gpa),
        .failures_only_in_b = try fonly_b.toOwnedSlice(gpa),
        .summary_diff = try buildSummaryDiff(gpa, sum_a, sum_b),
    };
}

fn compareEvents(gpa: Allocator, mid: []const u8, ea: types.Event, eb: types.Event, out: *std.ArrayList(EventDiff)) !void {
    if (!optI64Eq(ea.timestamp, eb.timestamp)) {
        try out.append(gpa, .{ .message_id = mid, .field = .timestamp, .value_a = try optI64(gpa, ea.timestamp), .value_b = try optI64(gpa, eb.timestamp) });
    }
    if (ea.direction != eb.direction) {
        try out.append(gpa, .{ .message_id = mid, .field = .direction, .value_a = ea.direction.toWire(), .value_b = eb.direction.toWire() });
    }
    if (!optTextEq(ea.action, eb.action)) {
        try out.append(gpa, .{ .message_id = mid, .field = .action, .value_a = optText(ea.action), .value_b = optText(eb.action) });
    }
    if (!deepEqual(ea.payload, eb.payload)) {
        try out.append(gpa, .{ .message_id = mid, .field = .payload, .value_a = try compactJson(gpa, ea.payload), .value_b = try compactJson(gpa, eb.payload) });
    }
    if (!optTextEq(ea.error_code, eb.error_code)) {
        try out.append(gpa, .{ .message_id = mid, .field = .error_code, .value_a = optText(ea.error_code), .value_b = optText(eb.error_code) });
    }
}

fn buildSummaryDiff(gpa: Allocator, a: ?types.SessionSummary, b: ?types.SessionSummary) !SummaryDiff {
    var diffs: std.ArrayList([]const u8) = .empty;

    if (a != null and b != null) {
        const sa = a.?;
        const sb = b.?;
        if (sa.event_count != sb.event_count)
            try diffs.append(gpa, try std.fmt.allocPrint(gpa, "Event count: A={d}, B={d}", .{ sa.event_count, sb.event_count }));
        if (sa.failure_count != sb.failure_count)
            try diffs.append(gpa, try std.fmt.allocPrint(gpa, "Failure count: A={d}, B={d}", .{ sa.failure_count, sb.failure_count }));
        if (sa.status != sb.status)
            try diffs.append(gpa, try std.fmt.allocPrint(gpa, "Session status: A=\"{s}\", B=\"{s}\"", .{ sa.status.toWire(), sb.status.toWire() }));
        if (!optI64Eq(sa.duration_ms, sb.duration_ms))
            try diffs.append(gpa, try std.fmt.allocPrint(gpa, "Duration: A={s}ms, B={s}ms", .{ try optI64(gpa, sa.duration_ms), try optI64(gpa, sb.duration_ms) }));
        if (!optI64Eq(sa.transaction_id, sb.transaction_id))
            try diffs.append(gpa, try std.fmt.allocPrint(gpa, "Transaction ID: A={s}, B={s}", .{ try optI64(gpa, sa.transaction_id), try optI64(gpa, sb.transaction_id) }));
    } else if (a != null and b == null) {
        try diffs.append(gpa, "Trace A has sessions but trace B does not");
    } else if (a == null and b != null) {
        try diffs.append(gpa, "Trace B has sessions but trace A does not");
    }

    return .{ .a = a, .b = b, .differences = try diffs.toOwnedSlice(gpa) };
}

// ---------------------------------------------------------------------------
// Value helpers
// ---------------------------------------------------------------------------

fn optI64Eq(a: ?i64, b: ?i64) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.? == b.?;
}

fn optTextEq(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn optI64(gpa: Allocator, v: ?i64) ![]const u8 {
    return if (v) |n| std.fmt.allocPrint(gpa, "{d}", .{n}) else "null";
}

fn optText(v: ?[]const u8) []const u8 {
    return v orelse "null";
}

/// Deep structural equality over JSON values, mirroring the toolkit's
/// `deepEqual`. Numbers compare by value across representations (`5 === 5.0`).
fn deepEqual(a: std.json.Value, b: std.json.Value) bool {
    const ta = std.meta.activeTag(a);
    const tb = std.meta.activeTag(b);
    if (ta != tb) {
        if (asF64(a)) |fa| {
            if (asF64(b)) |fb| return fa == fb;
        }
        return false;
    }
    return switch (a) {
        .null => true,
        .bool => a.bool == b.bool,
        .integer => a.integer == b.integer,
        .float => a.float == b.float,
        .number_string => std.mem.eql(u8, a.number_string, b.number_string),
        .string => std.mem.eql(u8, a.string, b.string),
        .array => blk: {
            if (a.array.items.len != b.array.items.len) break :blk false;
            for (a.array.items, b.array.items) |ia, ib| {
                if (!deepEqual(ia, ib)) break :blk false;
            }
            break :blk true;
        },
        .object => blk: {
            if (a.object.count() != b.object.count()) break :blk false;
            var oit = a.object.iterator();
            while (oit.next()) |e| {
                const bv = b.object.get(e.key_ptr.*) orelse break :blk false;
                if (!deepEqual(e.value_ptr.*, bv)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn asF64(v: std.json.Value) ?f64 {
    return switch (v) {
        .integer => |n| @as(f64, @floatFromInt(n)),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

fn compactJson(gpa: Allocator, v: std.json.Value) ![]const u8 {
    var buf: Buf = .empty;
    errdefer buf.deinit(gpa);
    try writeCompactJson(&buf, gpa, v);
    return buf.toOwnedSlice(gpa);
}

fn writeCompactJson(buf: *Buf, gpa: Allocator, v: std.json.Value) Allocator.Error!void {
    switch (v) {
        .null => try buf.appendSlice(gpa, "null"),
        .bool => |b| try buf.appendSlice(gpa, if (b) "true" else "false"),
        .integer => |n| try appf(buf, gpa, "{d}", .{n}),
        .float => |f| try appf(buf, gpa, "{d}", .{f}),
        .number_string => |s| try buf.appendSlice(gpa, s),
        .string => |s| try emitJsonString(buf, gpa, s),
        .array => |arr| {
            try buf.append(gpa, '[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try buf.append(gpa, ',');
                try writeCompactJson(buf, gpa, item);
            }
            try buf.append(gpa, ']');
        },
        .object => |obj| {
            try buf.append(gpa, '{');
            const keys = obj.keys();
            const vals = obj.values();
            for (keys, vals, 0..) |k, vl, i| {
                if (i > 0) try buf.append(gpa, ',');
                try emitJsonString(buf, gpa, k);
                try buf.append(gpa, ':');
                try writeCompactJson(buf, gpa, vl);
            }
            try buf.append(gpa, '}');
        },
    }
}

fn emitJsonString(buf: *Buf, gpa: Allocator, s: []const u8) !void {
    try buf.append(gpa, '"');
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice(gpa, "\\\""),
        '\\' => try buf.appendSlice(gpa, "\\\\"),
        '\n' => try buf.appendSlice(gpa, "\\n"),
        '\r' => try buf.appendSlice(gpa, "\\r"),
        '\t' => try buf.appendSlice(gpa, "\\t"),
        else => if (c < 0x20) try appf(buf, gpa, "\\u{x:0>4}", .{c}) else try buf.append(gpa, c),
    };
    try buf.append(gpa, '"');
}

fn appf(buf: *Buf, gpa: Allocator, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(gpa, fmt, args);
    defer gpa.free(s);
    try buf.appendSlice(gpa, s);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const parser = @import("parser.zig");

fn field(m: []const EventDiff, mid: []const u8, f: DiffField) ?EventDiff {
    for (m) |d| {
        if (d.field == f and std.mem.eql(u8, d.message_id, mid)) return d;
    }
    return null;
}

test "identical traces produce an empty diff" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const trace =
        \\{"events":[
        \\  {"timestamp":"2024-01-01T00:00:00Z","message":[2,"m1","BootNotification",{"x":1}]},
        \\  {"timestamp":"2024-01-01T00:00:10Z","message":[2,"m2","Heartbeat",{}]}
        \\]}
    ;
    const pa = try parser.parseTrace(a, trace);
    const pb = try parser.parseTrace(a, trace);
    const d = try diffTraces(a, pa, pb);

    try testing.expectEqual(@as(usize, 0), d.only_in_a.len);
    try testing.expectEqual(@as(usize, 0), d.only_in_b.len);
    try testing.expectEqual(@as(usize, 0), d.modified.len);
    try testing.expectEqual(@as(usize, 0), d.failures_only_in_a.len);
    try testing.expectEqual(@as(usize, 0), d.summary_diff.differences.len);
}

test "added and removed events are partitioned by messageId" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ta = "{\"events\":[{\"message\":[2,\"m1\",\"Heartbeat\",{}]},{\"message\":[2,\"m2\",\"Heartbeat\",{}]}]}";
    const tb = "{\"events\":[{\"message\":[2,\"m1\",\"Heartbeat\",{}]},{\"message\":[2,\"m3\",\"Heartbeat\",{}]}]}";
    const d = try diffTraces(a, try parser.parseTrace(a, ta), try parser.parseTrace(a, tb));

    try testing.expectEqual(@as(usize, 1), d.only_in_a.len);
    try testing.expectEqualStrings("m2", d.only_in_a[0].message_id);
    try testing.expectEqual(@as(usize, 1), d.only_in_b.len);
    try testing.expectEqualStrings("m3", d.only_in_b[0].message_id);
    try testing.expectEqual(@as(usize, 0), d.modified.len);
}

test "modified fields are detected with rendered values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Millisecond-scale timestamps (>= 1e12) pass through the normalizer as-is;
    // sub-1e12 values would be reinterpreted as epoch seconds.
    const ta = "{\"events\":[{\"timestamp\":1704067200000,\"message\":[2,\"m1\",\"Heartbeat\",{}]}]}";
    const tb = "{\"events\":[{\"timestamp\":1704067201000,\"message\":[2,\"m1\",\"BootNotification\",{\"x\":1}]}]}";
    const d = try diffTraces(a, try parser.parseTrace(a, ta), try parser.parseTrace(a, tb));

    const ts = field(d.modified, "m1", .timestamp) orelse return error.MissingTimestampDiff;
    try testing.expectEqualStrings("1704067200000", ts.value_a);
    try testing.expectEqualStrings("1704067201000", ts.value_b);

    const act = field(d.modified, "m1", .action) orelse return error.MissingActionDiff;
    try testing.expectEqualStrings("Heartbeat", act.value_a);
    try testing.expectEqualStrings("BootNotification", act.value_b);

    const pl = field(d.modified, "m1", .payload) orelse return error.MissingPayloadDiff;
    try testing.expectEqualStrings("{}", pl.value_a);
    try testing.expectEqualStrings("{\"x\":1}", pl.value_b);
}

test "deep payload equality ignores nested-equal, flags nested-different" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Nested-equal payloads: no payload diff.
    const same_a = "{\"events\":[{\"message\":[2,\"m1\",\"X\",{\"a\":{\"b\":[1,2,3]}}]}]}";
    const same_b = "{\"events\":[{\"message\":[2,\"m1\",\"X\",{\"a\":{\"b\":[1,2,3]}}]}]}";
    const d1 = try diffTraces(a, try parser.parseTrace(a, same_a), try parser.parseTrace(a, same_b));
    try testing.expect(field(d1.modified, "m1", .payload) == null);

    // One nested leaf differs: a payload diff appears.
    const diff_b = "{\"events\":[{\"message\":[2,\"m1\",\"X\",{\"a\":{\"b\":[1,2,4]}}]}]}";
    const d2 = try diffTraces(a, try parser.parseTrace(a, same_a), try parser.parseTrace(a, diff_b));
    try testing.expect(field(d2.modified, "m1", .payload) != null);
}

test "failure-set and summary differences over failed-auth vs normal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const failed = @embedFile("conformance/fixtures/failed-auth.json");
    const normal = @embedFile("conformance/fixtures/normal-session.json");
    const d = try diffTraces(a, try parser.parseTrace(a, failed), try parser.parseTrace(a, normal));

    // failed-auth detects a failure the clean trace does not.
    try testing.expect(d.failures_only_in_a.len > 0);
    // The two traces summarize differently (event/failure counts, or one having a
    // session the other lacks) — either way, at least one difference line.
    try testing.expect(d.summary_diff.differences.len > 0);
}
