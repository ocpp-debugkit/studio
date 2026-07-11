//! Failure detection — analyzes events and sessions for known failure patterns.
//! Mirrors the toolkit's `core/detection.ts` (the shared conformance contract):
//! same rule ids, severities, and thresholds.
//!
//! The 16-rule taxonomy is defined in types.zig (`FailureCode`). Rules land in
//! three batches; `detectFailures` runs them in contract order. Conformance is
//! measured on the de-duplicated, sorted set of `FailureCode`s (conformance/).

const std = @import("std");
const types = @import("types.zig");

const Event = types.Event;
const Session = types.Session;
const Failure = types.Failure;
const FailureCode = types.FailureCode;
const FailureSeverity = types.FailureSeverity;

const FailureList = std.ArrayList(Failure);

// ---------------------------------------------------------------------------
// Per-code metadata (severity + remediation steps)
// ---------------------------------------------------------------------------

fn severityOf(code: FailureCode) FailureSeverity {
    return switch (code) {
        .failed_authorization => .warning,
        .connector_fault => .critical,
        .station_offline_during_session => .critical,
        .timeout_no_heartbeat => .warning,
        .meter_value_gap => .warning,
        .invalid_stop_reason => .info,
        .unexpected_start => .warning,
        .status_transition_violation => .warning,
        .diagnostics_failure => .critical,
        .firmware_update_failure => .warning,
        .suspicious_session_duration => .warning,
        .slow_response => .warning,
        .heartbeat_interval_violation => .info,
        .meter_value_anomaly => .warning,
        .unresponsive_csms => .critical,
        .repeated_boot_notification => .warning,
    };
}

fn suggestedSteps(code: FailureCode) []const []const u8 {
    return switch (code) {
        .failed_authorization => &.{
            "Verify the idTag is valid and not expired",
            "Check the CSMS local authorization list",
            "Ensure the idTag is not blocked or deactivated",
            "Review the Authorize response payload for rejection reason",
        },
        .connector_fault => &.{
            "Inspect the physical connector for damage or debris",
            "Check the connector lock mechanism",
            "Review the errorCode field for specific fault type",
            "Check station logs for hardware diagnostics",
            "Contact hardware vendor if fault persists",
        },
        .station_offline_during_session => &.{
            "Check the network connection between station and CSMS",
            "Verify the station has not lost power",
            "Review the WebSocket connection stability",
            "Check if the station firmware has a known stability issue",
            "Investigate if maintenance was performed on the station",
        },
        .timeout_no_heartbeat => &.{
            "Check the station network connectivity",
            "Verify the WebSocket connection is stable",
            "Review the station heartbeat interval configuration",
            "Check if the station has rebooted or lost power",
            "Inspect the CSMS for connection acceptance issues",
        },
        .meter_value_gap => &.{
            "Verify the meter is functioning correctly",
            "Check the meter value reporting interval configuration",
            "Inspect the OCPP connection stability during the session",
            "Review station logs for meter communication errors",
            "Consider hardware replacement if meter is faulty",
        },
        .invalid_stop_reason => &.{
            "Review the StopTransaction payload for the stop reason",
            "Check if the stop reason is within the OCPP 1.6 specification",
            "Investigate why the station used a non-standard reason",
            "Review station firmware for stop reason mapping bugs",
        },
        .unexpected_start => &.{
            "Verify the station performed BootNotification before starting a transaction",
            "Check if authorization was properly completed before StartTransaction",
            "Review the station startup sequence and timing",
            "Inspect the CSMS for delayed or missing responses",
        },
        .status_transition_violation => &.{
            "Review the connector status transition sequence",
            "Check if the station firmware follows the OCPP status model correctly",
            "Verify no manual overrides triggered invalid transitions",
            "Inspect the connector status history for anomalies",
        },
        .diagnostics_failure => &.{
            "Review the DiagnosticsStatusNotification payload for the specific status",
            "Check the station diagnostic logs for detailed error information",
            "Verify the station hardware diagnostics are passing",
            "Contact hardware vendor if diagnostics indicate hardware failure",
        },
        .firmware_update_failure => &.{
            "Review the FirmwareStatusNotification payload for the specific status",
            "Check if the firmware image was corrupted or incomplete",
            "Verify the station has sufficient storage for the firmware update",
            "Retry the firmware update after addressing the failure cause",
            "Contact the firmware provider if the image is defective",
        },
        .suspicious_session_duration => &.{
            "Review the session duration in the trace timeline",
            "For very short sessions: check if the transaction was aborted or authorization failed mid-session",
            "For very long sessions: check if the station forgot to send StopTransaction",
            "Verify the station clock is synchronized (NTP)",
            "Check if the session spans a maintenance window or firmware update",
        },
        .slow_response => &.{
            "Check the CSMS processing time for the affected message type",
            "Review system load and database performance on the CSMS",
            "Verify network latency between station and CSMS",
            "Check if the CSMS is running a long-running synchronous operation",
            "Review CSMS logs for the specific message ID",
        },
        .heartbeat_interval_violation => &.{
            "Verify the heartbeat interval configured on the station matches the BootNotification response",
            "Check for network instability causing delayed heartbeats",
            "Review the station clock synchronization (NTP)",
            "Check if the station firmware has a known heartbeat timing bug",
            "Inspect the WebSocket connection stability",
        },
        .meter_value_anomaly => &.{
            "Verify the meter is functioning correctly and is properly calibrated",
            "Check for meter communication errors or data corruption",
            "Review the meter value sampling and reporting configuration",
            "Inspect for potential tampering or hardware malfunction",
            "Contact the meter vendor if the issue persists",
        },
        .unresponsive_csms => &.{
            "Check if the CSMS was online and accepting connections during the session",
            "Verify the WebSocket connection was stable at the time of the unanswered Call",
            "Review CSMS logs for the specific message ID",
            "Check if the CSMS crashed or restarted during the session",
            "Inspect the network path between station and CSMS for packet loss",
        },
        .repeated_boot_notification => &.{
            "Check whether the station rebooted unexpectedly",
            "Review station power and network stability during the boot window",
            "Inspect station firmware logs for watchdog resets or startup failures",
            "Verify the CSMS accepts the BootNotification and returns a valid interval",
            "Contact the station vendor if repeated boots persist",
        },
    };
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

fn actionEql(e: Event, name: []const u8) bool {
    return e.action != null and std.mem.eql(u8, e.action.?, name);
}

fn isCall(e: Event, action: []const u8) bool {
    return e.message_type == .call and actionEql(e, action);
}

fn payloadStr(payload: std.json.Value, key: []const u8) ?[]const u8 {
    if (payload != .object) return null;
    const v = payload.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

/// idTagInfo.status from a CallResult (Authorize response).
fn authorizeStatus(e: Event) ?[]const u8 {
    if (e.message_type != .call_result or e.payload != .object) return null;
    const info = e.payload.object.get("idTagInfo") orelse return null;
    if (info != .object) return null;
    const status = info.object.get("status") orelse return null;
    return if (status == .string) status.string else null;
}

/// status from a StatusNotification Call.
fn statusNotificationStatus(e: Event) ?[]const u8 {
    if (!isCall(e, "StatusNotification")) return null;
    return payloadStr(e.payload, "status");
}

/// errorCode from a StatusNotification Call.
fn statusNotificationErrorCode(e: Event) ?[]const u8 {
    if (!isCall(e, "StatusNotification")) return null;
    return payloadStr(e.payload, "errorCode");
}

/// Append a failure, filling severity and remediation from the taxonomy.
fn add(
    arena: std.mem.Allocator,
    list: *FailureList,
    code: FailureCode,
    description: []const u8,
    event_ids: []const []const u8,
) !void {
    try list.append(arena, .{
        .code = code,
        .description = description,
        .severity = severityOf(code),
        .event_ids = event_ids,
        .suggested_steps = suggestedSteps(code),
    });
}

fn ids2(arena: std.mem.Allocator, a: []const u8, b: []const u8) ![]const []const u8 {
    return arena.dupe([]const u8, &[_][]const u8{ a, b });
}

// ---------------------------------------------------------------------------
// detectFailures
// ---------------------------------------------------------------------------

/// Detect failures across a trace's events and sessions. Failures are returned
/// in contract order (rule by rule); allocations come from `arena`.
pub fn detectFailures(arena: std.mem.Allocator, events: []const Event, sessions: []const Session) ![]Failure {
    var list: FailureList = .empty;

    // Foundational rules (contract rules 1–3).
    try detectFailedAuthorization(arena, events, &list);
    try detectConnectorFault(arena, events, &list);
    try detectStationOfflineDuringSession(arena, sessions, &list);

    return list.toOwnedSlice(arena);
}

// ---------------------------------------------------------------------------
// Rule 1: FAILED_AUTHORIZATION
// ---------------------------------------------------------------------------

/// An Authorize response whose idTagInfo.status is "Invalid".
fn detectFailedAuthorization(arena: std.mem.Allocator, events: []const Event, list: *FailureList) !void {
    for (events) |event| {
        if (event.message_type != .call_result) continue;

        // Match the Authorize Call by messageId.
        var matching: ?Event = null;
        for (events) |e| {
            if (isCall(e, "Authorize") and std.mem.eql(u8, e.message_id, event.message_id)) {
                matching = e;
                break;
            }
        }
        const call = matching orelse continue;

        const status = authorizeStatus(event) orelse continue;
        if (std.mem.eql(u8, status, "Invalid")) {
            const desc = try std.fmt.allocPrint(
                arena,
                "Authorization rejected: idTag returned \"Invalid\" status (messageId: {s})",
                .{event.message_id},
            );
            try add(arena, list, .failed_authorization, desc, try ids2(arena, call.id, event.id));
        }
    }
}

// ---------------------------------------------------------------------------
// Rule 2: CONNECTOR_FAULT
// ---------------------------------------------------------------------------

/// A "Faulted" StatusNotification between a StartTransaction and its
/// StopTransaction (or the end of the trace). One fault reported per session.
fn detectConnectorFault(arena: std.mem.Allocator, events: []const Event, list: *FailureList) !void {
    for (events, 0..) |start_event, start_index| {
        if (!isCall(start_event, "StartTransaction")) continue;

        var stop_index: ?usize = null;
        var i = start_index + 1;
        while (i < events.len) : (i += 1) {
            if (isCall(events[i], "StopTransaction")) {
                stop_index = i;
                break;
            }
        }
        const search_end = stop_index orelse events.len;

        var j = start_index;
        while (j < search_end) : (j += 1) {
            const status = statusNotificationStatus(events[j]) orelse continue;
            if (!std.mem.eql(u8, status, "Faulted")) continue;

            const desc = if (statusNotificationErrorCode(events[j])) |ec|
                try std.fmt.allocPrint(
                    arena,
                    "Connector fault detected during active session: status \"Faulted\", errorCode \"{s}\" (messageId: {s})",
                    .{ ec, events[j].message_id },
                )
            else
                try std.fmt.allocPrint(
                    arena,
                    "Connector fault detected during active session: status \"Faulted\" (messageId: {s})",
                    .{events[j].message_id},
                );
            try add(arena, list, .connector_fault, desc, try ids2(arena, start_event.id, events[j].id));
            break; // one fault per session
        }
    }
}

// ---------------------------------------------------------------------------
// Rule 3: STATION_OFFLINE_DURING_SESSION
// ---------------------------------------------------------------------------

/// A transaction session that starts but never stops, or that reports an
/// Unavailable/Offline status between its Start and Stop.
fn detectStationOfflineDuringSession(arena: std.mem.Allocator, sessions: []const Session, list: *FailureList) !void {
    for (sessions) |session| {
        const tx = session.transaction_id orelse continue;

        var has_start = false;
        var has_stop = false;
        for (session.events) |e| {
            if (isCall(e, "StartTransaction")) has_start = true;
            if (isCall(e, "StopTransaction")) has_stop = true;
        }

        if (has_start and !has_stop) {
            var event_ids: std.ArrayList([]const u8) = .empty;
            for (session.events) |e| {
                if (isCall(e, "StartTransaction")) try event_ids.append(arena, e.id);
            }
            const desc = try std.fmt.allocPrint(
                arena,
                "Session {s} (transaction {d}) has a StartTransaction but no StopTransaction — station may have gone offline during an active session",
                .{ session.session_id, tx },
            );
            try add(arena, list, .station_offline_during_session, desc, try event_ids.toOwnedSlice(arena));
            continue;
        }

        if (has_start and has_stop) {
            var start_idx: ?usize = null;
            var stop_idx: ?usize = null;
            for (session.events, 0..) |e, idx| {
                if (start_idx == null and isCall(e, "StartTransaction")) start_idx = idx;
                if (stop_idx == null and isCall(e, "StopTransaction")) stop_idx = idx;
            }
            if (start_idx) |si| if (stop_idx) |sti| {
                var k = si;
                while (k <= sti) : (k += 1) {
                    const status = statusNotificationStatus(session.events[k]) orelse continue;
                    if (std.mem.eql(u8, status, "Unavailable") or std.mem.eql(u8, status, "Offline")) {
                        const desc = try std.fmt.allocPrint(
                            arena,
                            "Station reported \"{s}\" status during active session {s} (transaction {d})",
                            .{ status, session.session_id, tx },
                        );
                        try add(arena, list, .station_offline_during_session, desc, try arena.dupe([]const u8, &[_][]const u8{session.events[k].id}));
                        break;
                    }
                }
            };
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const parser = @import("parser.zig");
const timeline = @import("timeline.zig");

/// Parse a trace, correlate it, and run detection — the real pipeline.
fn detect(arena: std.mem.Allocator, trace_json: []const u8) ![]Failure {
    const parsed = try parser.parseTrace(arena, trace_json);
    const sessions = try timeline.buildSessionTimeline(arena, parsed.events);
    return detectFailures(arena, parsed.events, sessions);
}

/// True if `failures` contains `code`.
fn has(failures: []const Failure, code: FailureCode) bool {
    for (failures) |f| {
        if (f.code == code) return true;
    }
    return false;
}

test "FAILED_AUTHORIZATION fires on an Invalid Authorize response" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const rejected = try detect(a,
        \\{"events":[
        \\{"message":[2,"m1","Authorize",{"idTag":"TAG-BAD"}]},
        \\{"message":[3,"m1",{"idTagInfo":{"status":"Invalid"}}]}]}
    );
    try testing.expectEqual(@as(usize, 1), rejected.len);
    try testing.expectEqual(FailureCode.failed_authorization, rejected[0].code);
    try testing.expectEqual(FailureSeverity.warning, rejected[0].severity);
    try testing.expectEqual(@as(usize, 2), rejected[0].event_ids.len);
    try testing.expect(rejected[0].suggested_steps.len > 0);

    const accepted = try detect(a,
        \\{"events":[
        \\{"message":[2,"m1","Authorize",{"idTag":"TAG-OK"}]},
        \\{"message":[3,"m1",{"idTagInfo":{"status":"Accepted"}}]}]}
    );
    try testing.expectEqual(@as(usize, 0), accepted.len);
}

test "CONNECTOR_FAULT fires on a Faulted status during a transaction" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const faulted = try detect(a,
        \\{"events":[
        \\{"message":[2,"b1","BootNotification",{"chargePointSerialNumber":"CS-1"}]},
        \\{"message":[3,"b1",{"status":"Accepted","interval":300}]},
        \\{"message":[2,"s1","StartTransaction",{"connectorId":1,"meterStart":0}]},
        \\{"message":[3,"s1",{"transactionId":501}]},
        \\{"message":[2,"n1","StatusNotification",{"connectorId":1,"status":"Faulted","errorCode":"GroundFailure"}]},
        \\{"message":[2,"e1","StopTransaction",{"transactionId":501,"meterStop":10,"reason":"EmergencyStop"}]},
        \\{"message":[3,"e1",{"idTagInfo":{"status":"Accepted"}}]}]}
    );
    try testing.expect(has(faulted, .connector_fault));
    try testing.expectEqual(FailureSeverity.critical, faulted[0].severity);

    // A healthy session raises nothing.
    const healthy = try detect(a,
        \\{"events":[
        \\{"message":[2,"s1","StartTransaction",{"connectorId":1,"meterStart":0}]},
        \\{"message":[3,"s1",{"transactionId":502}]},
        \\{"message":[2,"n1","StatusNotification",{"connectorId":1,"status":"Charging"}]},
        \\{"message":[2,"e1","StopTransaction",{"transactionId":502,"meterStop":10,"reason":"Local"}]},
        \\{"message":[3,"e1",{"idTagInfo":{"status":"Accepted"}}]}]}
    );
    try testing.expect(!has(healthy, .connector_fault));
}

test "STATION_OFFLINE_DURING_SESSION fires on a start with no stop" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const orphaned = try detect(a,
        \\{"events":[
        \\{"message":[2,"b1","BootNotification",{"chargePointSerialNumber":"CS-1"}]},
        \\{"message":[3,"b1",{"status":"Accepted","interval":300}]},
        \\{"message":[2,"s1","StartTransaction",{"connectorId":1,"meterStart":0}]},
        \\{"message":[3,"s1",{"transactionId":777}]}]}
    );
    try testing.expect(has(orphaned, .station_offline_during_session));
    try testing.expectEqual(FailureSeverity.critical, orphaned[0].severity);

    // A completed transaction does not.
    const completed = try detect(a,
        \\{"events":[
        \\{"message":[2,"s1","StartTransaction",{"connectorId":1,"meterStart":0}]},
        \\{"message":[3,"s1",{"transactionId":778}]},
        \\{"message":[2,"e1","StopTransaction",{"transactionId":778,"meterStop":10,"reason":"Local"}]},
        \\{"message":[3,"e1",{"idTagInfo":{"status":"Accepted"}}]}]}
    );
    try testing.expect(!has(completed, .station_offline_during_session));
}
