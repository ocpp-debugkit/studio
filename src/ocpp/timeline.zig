//! Session timeline — correlates normalized events into logical charging
//! sessions. Mirrors the toolkit's `core/timeline.ts` (the shared conformance
//! contract), not its source.
//!
//! Correlation strategy:
//!   1. Primary key: transactionId — from the StartTransaction response, and
//!      from StopTransaction / MeterValues request payloads. Responses inherit
//!      their Call's transactionId by messageId.
//!   2. Un-keyed events are distributed to sessions by connectorId and time
//!      proximity; BootNotification / Heartbeat attach to the first session.
//!   3. A trace with no StartTransaction collapses to a single session.

const std = @import("std");
const types = @import("types.zig");

const Event = types.Event;
const Session = types.Session;
const Status = types.Status;

// ---------------------------------------------------------------------------
// Payload / event helpers
// ---------------------------------------------------------------------------

fn payloadInt(payload: std.json.Value, key: []const u8) ?i64 {
    if (payload != .object) return null;
    const v = payload.object.get(key) orelse return null;
    return if (v == .integer) v.integer else null;
}

fn payloadStr(payload: std.json.Value, key: []const u8) ?[]const u8 {
    if (payload != .object) return null;
    const v = payload.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn actionEql(e: Event, name: []const u8) bool {
    return e.action != null and std.mem.eql(u8, e.action.?, name);
}

/// The transactionId an event carries, if any. StartTransaction Calls carry
/// none (their response does); StopTransaction / MeterValues Calls and any
/// CallResult may carry one in the payload.
fn extractTransactionId(e: Event) ?i64 {
    switch (e.message_type) {
        .call => {
            if (actionEql(e, "StartTransaction")) return null;
            if (actionEql(e, "StopTransaction") or actionEql(e, "MeterValues")) {
                return payloadInt(e.payload, "transactionId");
            }
            return null;
        },
        .call_result => return payloadInt(e.payload, "transactionId"),
        .call_error => return null,
    }
}

fn extractConnectorId(e: Event) ?i64 {
    if (e.message_type != .call) return null;
    return payloadInt(e.payload, "connectorId");
}

fn extractStationId(events: []const Event) []const u8 {
    for (events) |e| {
        if (e.message_type == .call and actionEql(e, "BootNotification")) {
            if (payloadStr(e.payload, "chargePointSerialNumber")) |s| return s;
        }
    }
    return "unknown";
}

fn isStartTransaction(e: Event) bool {
    return e.message_type == .call and actionEql(e, "StartTransaction");
}

fn isStopTransaction(e: Event) bool {
    return e.message_type == .call and actionEql(e, "StopTransaction");
}

fn isFaultedStatus(e: Event) bool {
    if (e.message_type != .call or !actionEql(e, "StatusNotification")) return false;
    const s = payloadStr(e.payload, "status") orelse return false;
    return std.mem.eql(u8, s, "Faulted");
}

fn isUnavailableStatus(e: Event) bool {
    if (e.message_type != .call or !actionEql(e, "StatusNotification")) return false;
    const s = payloadStr(e.payload, "status") orelse return false;
    return std.mem.eql(u8, s, "Unavailable") or std.mem.eql(u8, s, "Offline");
}

// ---------------------------------------------------------------------------
// buildSessionTimeline
// ---------------------------------------------------------------------------

const EventList = std.ArrayList(Event);

/// Build session timelines from normalized events. Sessions are ordered by
/// start time and numbered `session-0…`. Allocations come from `arena`; the
/// result borrows from it.
pub fn buildSessionTimeline(arena: std.mem.Allocator, events: []const Event) ![]Session {
    if (events.len == 0) return &[_]Session{};

    const station_id = extractStationId(events);

    // messageId → transactionId from CallResults carrying one (StartTransaction
    // responses supply the id its Call lacked).
    var response_tx = std.StringHashMap(i64).init(arena);
    defer response_tx.deinit();
    for (events) |e| {
        if (e.message_type == .call_result) {
            if (extractTransactionId(e)) |tx| try response_tx.put(e.message_id, tx);
        }
    }

    var has_start = false;
    for (events) |e| {
        if (isStartTransaction(e)) {
            has_start = true;
            break;
        }
    }

    // No transactions → one session holding every event.
    if (!has_start) {
        const one = try arena.alloc(Session, 1);
        one[0] = try createSession(arena, "session-0", station_id, events, null, null);
        return one;
    }

    // messageId → transactionId for Call messages: Stop/Meter from payload,
    // StartTransaction from its matched response.
    var call_tx = std.StringHashMap(i64).init(arena);
    defer call_tx.deinit();
    for (events) |e| {
        if (e.message_type != .call) continue;
        if (extractTransactionId(e)) |tx| try call_tx.put(e.message_id, tx);
        if (actionEql(e, "StartTransaction")) {
            if (response_tx.get(e.message_id)) |tx| try call_tx.put(e.message_id, tx);
        }
    }

    // Group events by transactionId, preserving first-seen order. Un-keyed
    // events wait in `null_events` for distribution.
    var groups: std.AutoArrayHashMapUnmanaged(i64, EventList) = .empty;
    defer groups.deinit(arena);
    var null_events: EventList = .empty;

    for (events) |e| {
        const tx: ?i64 = switch (e.message_type) {
            .call, .call_result => call_tx.get(e.message_id) orelse extractTransactionId(e),
            .call_error => null,
        };
        if (tx) |txid| {
            const gop = try groups.getOrPut(arena, txid);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(arena, e);
        } else {
            try null_events.append(arena, e);
        }
    }

    var used_null = std.StringHashMap(void).init(arena);
    defer used_null.deinit();

    var sessions: std.ArrayList(Session) = .empty;
    var session_index: usize = 0;

    var it = groups.iterator();
    while (it.next()) |entry| {
        const txid = entry.key_ptr.*;
        const tx_events = entry.value_ptr.*.items;

        var connector_id: ?i64 = null;
        for (tx_events) |e| {
            if (isStartTransaction(e)) {
                connector_id = extractConnectorId(e);
                break;
            }
        }

        var tx_msg_ids = std.StringHashMap(void).init(arena);
        defer tx_msg_ids.deinit();
        for (tx_events) |e| try tx_msg_ids.put(e.message_id, {});

        const session_start = if (tx_events.len > 0) tx_events[0].timestamp else null;
        const session_end = if (tx_events.len > 0) tx_events[tx_events.len - 1].timestamp else null;

        var related: EventList = .empty;
        for (null_events.items) |e| {
            if (used_null.contains(e.id)) continue;
            if (shouldAttach(e, connector_id, session_start, session_end, session_index, &tx_msg_ids)) {
                try related.append(arena, e);
            }
        }
        for (related.items) |e| try used_null.put(e.id, {});

        var all: EventList = .empty;
        try all.appendSlice(arena, tx_events);
        try all.appendSlice(arena, related.items);
        std.mem.sort(Event, all.items, {}, lessById);

        const label = try std.fmt.allocPrint(arena, "session-{d}", .{session_index});
        try sessions.append(arena, try createSession(arena, label, station_id, all.items, connector_id, txid));
        session_index += 1;
    }

    std.mem.sort(Session, sessions.items, {}, lessByStartTime);
    for (sessions.items, 0..) |*s, i| {
        s.session_id = try std.fmt.allocPrint(arena, "session-{d}", .{i});
    }

    return sessions.toOwnedSlice(arena);
}

/// Decide whether an un-keyed event belongs to the session under construction —
/// the toolkit's null-event distribution rules, in order.
fn shouldAttach(
    e: Event,
    connector_id: ?i64,
    session_start: ?i64,
    session_end: ?i64,
    session_index: usize,
    tx_msg_ids: *std.StringHashMap(void),
) bool {
    // A response to a Call already in the session.
    if (e.message_type != .call and tx_msg_ids.contains(e.message_id)) return true;

    // Same connector: within [start, end + 1 min], or include when timestamps
    // are missing.
    if (extractConnectorId(e)) |eci| {
        if (connector_id) |cid| {
            if (eci == cid) {
                if (session_start) |ss| if (session_end) |se| if (e.timestamp) |ts| {
                    return ts >= ss and ts <= se + 60_000;
                };
                return true;
            }
        }
    }

    const is_boot = actionEql(e, "BootNotification");
    const is_hb = actionEql(e, "Heartbeat");
    if (is_boot or is_hb) return session_index == 0;

    // Connector-less Calls (e.g. Authorize): from 5 min before start to 1 min
    // after end.
    if (extractConnectorId(e) == null and e.message_type == .call and !is_boot and !is_hb) {
        if (session_start) |ss| if (session_end) |se| if (e.timestamp) |ts| {
            return ts >= ss - 300_000 and ts <= se + 60_000;
        };
    }
    return false;
}

fn createSession(
    arena: std.mem.Allocator,
    session_id: []const u8,
    station_id: []const u8,
    evs: []const Event,
    connector_id: ?i64,
    tx_in: ?i64,
) !Session {
    var start: ?i64 = null;
    var end: ?i64 = null;
    for (evs) |e| {
        if (e.timestamp) |t| {
            if (start == null or t < start.?) start = t;
            if (end == null or t > end.?) end = t;
        }
    }

    var has_stop = false;
    var has_faulted = false;
    var has_unavailable = false;
    for (evs) |e| {
        if (isStopTransaction(e)) has_stop = true;
        if (isFaultedStatus(e)) has_faulted = true;
        if (isUnavailableStatus(e)) has_unavailable = true;
    }
    const status: Status = if (has_stop)
        .completed
    else if (has_faulted or has_unavailable)
        .aborted
    else
        .active;

    var tx = tx_in;
    if (tx == null) {
        for (evs) |e| {
            if (extractTransactionId(e)) |t| {
                tx = t;
                break;
            }
        }
    }

    return .{
        .session_id = session_id,
        .station_id = station_id,
        .connector_id = connector_id,
        .transaction_id = tx,
        .start_time = start,
        .end_time = end,
        .events = try arena.dupe(Event, evs),
        .status = status,
    };
}

fn lessById(_: void, a: Event, b: Event) bool {
    return std.mem.order(u8, a.id, b.id) == .lt;
}

fn lessByStartTime(_: void, a: Session, b: Session) bool {
    const at = a.start_time orelse return false; // nulls sort last
    const bt = b.start_time orelse return true;
    return at < bt;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const parser = @import("parser.zig");

/// Build an `Event` directly (bypassing the parser), mirroring the toolkit's
/// `makeEvent`. Timeline reads message_type / action / payload / message_id /
/// timestamp — not raw_message — so raw_message is left null.
fn ev(
    arena: std.mem.Allocator,
    id: []const u8,
    message_id: []const u8,
    message_type: types.MessageType,
    action: ?[]const u8,
    payload_json: []const u8,
    timestamp: ?i64,
) Event {
    return .{
        .id = id,
        .message_id = message_id,
        .timestamp = timestamp,
        .direction = .cs_to_csms,
        .message_type = message_type,
        .action = action,
        .payload = std.json.parseFromSliceLeaky(std.json.Value, arena, payload_json, .{}) catch unreachable,
        .error_code = null,
        .error_description = null,
        .raw_message = .null,
    };
}

fn normalSessionEvents(a: std.mem.Allocator) []Event {
    var list: EventList = .empty;
    list.append(a, ev(a, "evt-0001", "msg-001", .call, "BootNotification", "{\"chargePointSerialNumber\":\"CS-001\"}", 1000)) catch unreachable;
    list.append(a, ev(a, "evt-0002", "msg-001", .call_result, null, "{\"status\":\"Accepted\"}", 1500)) catch unreachable;
    list.append(a, ev(a, "evt-0003", "msg-002", .call, "StatusNotification", "{\"connectorId\":0,\"status\":\"Available\"}", 2000)) catch unreachable;
    list.append(a, ev(a, "evt-0004", "msg-002", .call_result, null, "{}", 2500)) catch unreachable;
    list.append(a, ev(a, "evt-0005", "msg-003", .call, "Authorize", "{\"idTag\":\"TAG-001\"}", 3000)) catch unreachable;
    list.append(a, ev(a, "evt-0006", "msg-003", .call_result, null, "{\"idTagInfo\":{\"status\":\"Accepted\"}}", 3500)) catch unreachable;
    list.append(a, ev(a, "evt-0007", "msg-004", .call, "StartTransaction", "{\"connectorId\":1,\"idTag\":\"TAG-001\",\"meterStart\":0}", 4000)) catch unreachable;
    list.append(a, ev(a, "evt-0008", "msg-004", .call_result, null, "{\"transactionId\":100001,\"idTagInfo\":{\"status\":\"Accepted\"}}", 4500)) catch unreachable;
    list.append(a, ev(a, "evt-0009", "msg-005", .call, "StatusNotification", "{\"connectorId\":1,\"status\":\"Charging\"}", 5000)) catch unreachable;
    list.append(a, ev(a, "evt-0010", "msg-005", .call_result, null, "{}", 5500)) catch unreachable;
    list.append(a, ev(a, "evt-0011", "msg-006", .call, "MeterValues", "{\"connectorId\":1,\"transactionId\":100001,\"meterValue\":[]}", 6000)) catch unreachable;
    list.append(a, ev(a, "evt-0012", "msg-006", .call_result, null, "{}", 6500)) catch unreachable;
    list.append(a, ev(a, "evt-0013", "msg-007", .call, "StopTransaction", "{\"transactionId\":100001,\"meterStop\":10000,\"reason\":\"EVDisconnected\"}", 7000)) catch unreachable;
    list.append(a, ev(a, "evt-0014", "msg-007", .call_result, null, "{\"idTagInfo\":{\"status\":\"Accepted\"}}", 7500)) catch unreachable;
    return list.items;
}

test "a normal session correlates into one completed session" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const sessions = try buildSessionTimeline(a, normalSessionEvents(a));
    try testing.expectEqual(@as(usize, 1), sessions.len);
    try testing.expectEqual(@as(?i64, 100001), sessions[0].transaction_id);
    try testing.expectEqual(Status.completed, sessions[0].status);
    try testing.expectEqual(@as(?i64, 1), sessions[0].connector_id);
    try testing.expectEqualStrings("CS-001", sessions[0].station_id);
    try testing.expectEqual(@as(?i64, 1000), sessions[0].start_time);
    try testing.expectEqual(@as(?i64, 7500), sessions[0].end_time);
}

test "stationId falls back to unknown without a BootNotification" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const events = [_]Event{ev(a, "evt-0001", "msg-001", .call, "Authorize", "{\"idTag\":\"TAG-001\"}", 1000)};
    const sessions = try buildSessionTimeline(a, &events);
    try testing.expectEqual(@as(usize, 1), sessions.len);
    try testing.expectEqualStrings("unknown", sessions[0].station_id);
}

test "status is active without a StopTransaction" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const events = [_]Event{
        ev(a, "evt-0001", "msg-001", .call, "BootNotification", "{\"chargePointSerialNumber\":\"CS-001\"}", 1000),
        ev(a, "evt-0002", "msg-002", .call, "StartTransaction", "{\"connectorId\":1,\"meterStart\":0}", 2000),
        ev(a, "evt-0003", "msg-002", .call_result, null, "{\"transactionId\":200001}", 2500),
    };
    const sessions = try buildSessionTimeline(a, &events);
    try testing.expectEqual(Status.active, sessions[0].status);
    try testing.expectEqual(@as(?i64, 200001), sessions[0].transaction_id);
}

test "status is aborted on a fault with no StopTransaction" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const events = [_]Event{
        ev(a, "evt-0001", "msg-001", .call, "StartTransaction", "{\"connectorId\":1,\"meterStart\":0}", 2000),
        ev(a, "evt-0002", "msg-001", .call_result, null, "{\"transactionId\":400001}", 2500),
        ev(a, "evt-0003", "msg-002", .call, "StatusNotification", "{\"connectorId\":1,\"status\":\"Faulted\"}", 3000),
    };
    const sessions = try buildSessionTimeline(a, &events);
    try testing.expectEqual(@as(usize, 1), sessions.len);
    try testing.expectEqual(Status.aborted, sessions[0].status);
}

test "a trace with no transactions collapses to one session" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const events = [_]Event{
        ev(a, "evt-0001", "msg-001", .call, "BootNotification", "{\"chargePointSerialNumber\":\"CS-001\"}", 1000),
        ev(a, "evt-0002", "msg-001", .call_result, null, "{\"status\":\"Accepted\"}", 1500),
        ev(a, "evt-0003", "msg-002", .call, "Heartbeat", "{}", 2000),
        ev(a, "evt-0004", "msg-002", .call_result, null, "{\"currentTime\":\"2024-01-15T10:00:00.000Z\"}", 2500),
    };
    const sessions = try buildSessionTimeline(a, &events);
    try testing.expectEqual(@as(usize, 1), sessions.len);
    try testing.expectEqual(@as(?i64, null), sessions[0].transaction_id);
}

test "empty events yield no sessions" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const sessions = try buildSessionTimeline(arena_state.allocator(), &[_]Event{});
    try testing.expectEqual(@as(usize, 0), sessions.len);
}

test "two transactions produce two time-ordered sessions" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const events = [_]Event{
        ev(a, "evt-0001", "msg-001", .call, "BootNotification", "{\"chargePointSerialNumber\":\"CS-001\"}", 1000),
        ev(a, "evt-0002", "msg-001", .call_result, null, "{\"status\":\"Accepted\"}", 1500),
        ev(a, "evt-0003", "msg-002", .call, "StartTransaction", "{\"connectorId\":1,\"meterStart\":0}", 2000),
        ev(a, "evt-0004", "msg-002", .call_result, null, "{\"transactionId\":100001}", 2500),
        ev(a, "evt-0005", "msg-003", .call, "StopTransaction", "{\"transactionId\":100001,\"meterStop\":5000}", 3000),
        ev(a, "evt-0006", "msg-003", .call_result, null, "{\"idTagInfo\":{\"status\":\"Accepted\"}}", 3500),
        ev(a, "evt-0007", "msg-004", .call, "StartTransaction", "{\"connectorId\":2,\"meterStart\":0}", 4000),
        ev(a, "evt-0008", "msg-004", .call_result, null, "{\"transactionId\":100002}", 4500),
        ev(a, "evt-0009", "msg-005", .call, "StopTransaction", "{\"transactionId\":100002,\"meterStop\":3000}", 5000),
        ev(a, "evt-0010", "msg-005", .call_result, null, "{\"idTagInfo\":{\"status\":\"Accepted\"}}", 5500),
    };
    const sessions = try buildSessionTimeline(a, &events);
    try testing.expectEqual(@as(usize, 2), sessions.len);
    try testing.expectEqual(@as(?i64, 100001), sessions[0].transaction_id);
    try testing.expectEqual(@as(?i64, 100002), sessions[1].transaction_id);
    try testing.expectEqualStrings("session-0", sessions[0].session_id);
    try testing.expectEqualStrings("session-1", sessions[1].session_id);
}

test "end to end: parse the normal-session fixture and correlate it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const fixture = @embedFile("testdata/normal-session.json");
    const parsed = try parser.parseTrace(a, fixture);
    try testing.expectEqual(@as(usize, 22), parsed.events.len);
    try testing.expectEqual(@as(usize, 0), parsed.warnings.len);

    const sessions = try buildSessionTimeline(a, parsed.events);
    try testing.expectEqual(@as(usize, 1), sessions.len);
    try testing.expectEqual(@as(?i64, 100001), sessions[0].transaction_id);
    try testing.expectEqual(Status.completed, sessions[0].status);
    try testing.expectEqual(@as(?i64, 1), sessions[0].connector_id);
    try testing.expectEqualStrings("CS-SYNTHETIC-001", sessions[0].station_id);
    // BootNotification (earliest, 10:00:00.000Z) attaches to the first session.
    try testing.expectEqual(@as(?i64, 1_705_312_800_000), sessions[0].start_time);
}
