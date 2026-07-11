//! Conformance harness — pins Studio's detection to the toolkit's.
//!
//! For each of the 15 shared scenarios, the vendored **trace** runs through the
//! full engine (`parseTrace → buildSessionTimeline → detectFailures`) and its
//! de-duplicated, sorted `FailureCode` set is compared to the locked **golden**
//! — the same comparison semantics as the toolkit's `evaluateScenario`.
//!
//! Fixtures and goldens under `fixtures/` and `goldens/` are generated from the
//! toolkit (the source of truth), tagged `contract-v1`; they are not authored by
//! hand. See `README.md` in this directory. This layout lives under `src/` so the
//! zero-config build can `@embedFile` it (ADR-0004).

const std = @import("std");
const parser = @import("../parser.zig");
const timeline = @import("../timeline.zig");
const detection = @import("../detection.zig");

/// The 15 shared scenarios (the toolkit's `scenarioNames`).
const scenario_names = [_][]const u8{
    "normal-session",
    "failed-auth",
    "connector-fault",
    "station-offline",
    "unexpected-stop-reason",
    "meter-value-gap",
    "invalid-stop-reason",
    "unexpected-start",
    "status-transition-violation",
    "diagnostics-failure",
    "slow-csms-response",
    "meter-anomaly",
    "short-session",
    "heartbeat-irregular",
    "unresponsive-csms",
};

test "conformance: detected failure codes match the locked goldens" {
    var any_failed = false;
    inline for (scenario_names) |name| {
        runScenario(
            name,
            @embedFile("fixtures/" ++ name ++ ".json"),
            @embedFile("goldens/" ++ name ++ ".json"),
        ) catch {
            any_failed = true;
        };
    }
    try std.testing.expect(!any_failed);
}

fn runScenario(name: []const u8, trace_json: []const u8, golden_json: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Full engine pipeline over the vendored trace.
    const parsed = try parser.parseTrace(a, trace_json);
    const sessions = try timeline.buildSessionTimeline(a, parsed.events);
    const failures = try detection.detectFailures(a, parsed.events, sessions);

    // De-duplicate + sort the detected failure codes (evaluateScenario semantics).
    var seen = std.StringHashMap(void).init(a);
    var detected: std.ArrayList([]const u8) = .empty;
    for (failures) |f| {
        const code = f.code.toWire();
        const gop = try seen.getOrPut(code);
        if (!gop.found_existing) try detected.append(a, code);
    }
    std.mem.sort([]const u8, detected.items, {}, lessStr);

    // The golden is a sorted JSON array of wire codes; sort again defensively.
    const golden = try std.json.parseFromSliceLeaky([][]const u8, a, golden_json, .{ .allocate = .alloc_always });
    std.mem.sort([]const u8, golden, {}, lessStr);

    if (!equalCodes(golden, detected.items)) {
        std.debug.print("conformance mismatch [{s}]\n  expected: ", .{name});
        printCodes(golden);
        std.debug.print("\n  detected: ", .{});
        printCodes(detected.items);
        std.debug.print("\n", .{});
        return error.ConformanceMismatch;
    }
}

fn equalCodes(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn printCodes(codes: []const []const u8) void {
    std.debug.print("[", .{});
    for (codes, 0..) |c, i| {
        if (i > 0) std.debug.print(", ", .{});
        std.debug.print("{s}", .{c});
    }
    std.debug.print("]", .{});
}
