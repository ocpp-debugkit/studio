//! Session summarizer — overview statistics for a charging session (ADR-0003).
//!
//! Mirrors the toolkit's `core/summarizer.ts`. Pure and headless: derives each
//! session's event count, duration, and Call action sequence, and counts the
//! detected failures whose implicated events fall inside the session. The
//! reporter and the trace diff consume these projections.

const std = @import("std");
const types = @import("types.zig");

/// Summarize a single session. `failure_count` is supplied by the caller (see
/// `summarizeSessions`), mirroring the toolkit's two-argument `summarizeSession`.
/// The returned `action_sequence` is allocated from `allocator`.
pub fn summarizeSession(
    allocator: std.mem.Allocator,
    session: types.Session,
    failure_count: usize,
) !types.SessionSummary {
    var actions: std.ArrayList([]const u8) = .empty;
    for (session.events) |e| {
        if (e.message_type == .call) {
            if (e.action) |a| try actions.append(allocator, a);
        }
    }

    const duration_ms: ?i64 = if (session.start_time != null and session.end_time != null)
        session.end_time.? - session.start_time.?
    else
        null;

    return .{
        .session_id = session.session_id,
        .station_id = session.station_id,
        .connector_id = session.connector_id,
        .transaction_id = session.transaction_id,
        .status = session.status,
        .event_count = session.events.len,
        .duration_ms = duration_ms,
        .failure_count = failure_count,
        .action_sequence = try actions.toOwnedSlice(allocator),
    };
}

/// Summarize every session, counting the failures whose implicated events fall
/// within each session (matched by event id). Returns a slice parallel to
/// `sessions`, allocated from `allocator`.
pub fn summarizeSessions(
    allocator: std.mem.Allocator,
    sessions: []const types.Session,
    failures: []const types.Failure,
) ![]types.SessionSummary {
    const summaries = try allocator.alloc(types.SessionSummary, sessions.len);
    for (sessions, 0..) |session, i| {
        // A set of this session's event ids, to test failure membership.
        var event_ids = std.StringHashMap(void).init(allocator);
        defer event_ids.deinit();
        for (session.events) |e| try event_ids.put(e.id, {});

        var failure_count: usize = 0;
        for (failures) |f| {
            for (f.event_ids) |id| {
                if (event_ids.contains(id)) {
                    failure_count += 1;
                    break;
                }
            }
        }

        summaries[i] = try summarizeSession(allocator, session, failure_count);
    }
    return summaries;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const parser = @import("parser.zig");
const timeline = @import("timeline.zig");
const detection = @import("detection.zig");

test "summarizeSessions derives counts, duration, and the Call action sequence" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A minimal one-session trace: Boot, Authorize, StartTransaction, then a
    // StopTransaction — four Call actions, ~10s apart, correlated by txn id.
    const trace =
        \\{"events":[
        \\  {"timestamp":"2024-01-15T08:00:00Z","message":[2,"m1","BootNotification",{"chargePointVendor":"V"}]},
        \\  {"timestamp":"2024-01-15T08:00:10Z","message":[2,"m2","Authorize",{"idTag":"TAG"}]},
        \\  {"timestamp":"2024-01-15T08:00:20Z","message":[2,"m3","StartTransaction",{"connectorId":1,"idTag":"TAG","meterStart":0,"timestamp":"2024-01-15T08:00:20Z"}]},
        \\  {"timestamp":"2024-01-15T08:00:30Z","message":[3,"m3",{"transactionId":77,"idTagInfo":{"status":"Accepted"}}]},
        \\  {"timestamp":"2024-01-15T08:05:00Z","message":[2,"m4","StopTransaction",{"transactionId":77,"meterStop":100,"timestamp":"2024-01-15T08:05:00Z","reason":"Local"}]}
        \\]}
    ;

    const parsed = try parser.parseTrace(a, trace);
    const sessions = try timeline.buildSessionTimeline(a, parsed.events);
    const failures = try detection.detectFailures(a, parsed.events, sessions);
    const summaries = try summarizeSessions(a, sessions, failures);

    try testing.expectEqual(sessions.len, summaries.len);
    try testing.expect(summaries.len >= 1);

    const s = summaries[0];
    try testing.expectEqual(sessions[0].events.len, s.event_count);
    // Duration spans the correlated session window (non-null, positive).
    try testing.expect(s.duration_ms != null);
    try testing.expect(s.duration_ms.? > 0);
    // Only Call messages with an action contribute; the CallResult (m3) does not.
    for (s.action_sequence) |act| try testing.expect(act.len > 0);
    try testing.expect(s.action_sequence.len >= 1);
    try testing.expectEqualStrings("BootNotification", s.action_sequence[0]);
}

test "summarizeSession counts only failures touching the session's events" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const session = types.Session{
        .session_id = "session-1",
        .station_id = "station-1",
        .connector_id = 1,
        .transaction_id = 42,
        .start_time = 1000,
        .end_time = 4000,
        .events = &.{},
        .status = .completed,
    };

    const s = try summarizeSession(a, session, 3);
    try testing.expectEqual(@as(usize, 3), s.failure_count);
    try testing.expectEqual(@as(?i64, 3000), s.duration_ms);
    try testing.expectEqual(@as(usize, 0), s.event_count);
    try testing.expectEqual(@as(usize, 0), s.action_sequence.len);
}
