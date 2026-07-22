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

fn payloadInt(payload: std.json.Value, key: []const u8) ?i64 {
    if (payload != .object) return null;
    const v = payload.object.get(key) orelse return null;
    return if (v == .integer) v.integer else null;
}

fn inList(list: []const []const u8, value: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, value)) return true;
    }
    return false;
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
/// Above this event count, callers should skip `detectFailures`: several rules
/// are O(n²) in the event count (they mirror the toolkit's algorithms, written
/// for browser-scale traces). A trusted trace far past this still parses,
/// correlates, and is fully inspectable in the timeline — only the failure
/// analysis is bounded. Making the rules O(n) so detection scales to the full
/// trusted capacity is tracked as a follow-up (see ADR-0007). `detectFailures`
/// itself does not enforce this — the workspace does — so small-trace callers
/// (the conformance harness) are unaffected.
pub const max_events_for_detection: usize = 50_000;

pub fn detectFailures(arena: std.mem.Allocator, events: []const Event, sessions: []const Session) ![]Failure {
    var list: FailureList = .empty;

    // Foundational rules (contract rules 1–3).
    try detectFailedAuthorization(arena, events, &list);
    try detectConnectorFault(arena, events, &list);
    try detectStationOfflineDuringSession(arena, sessions, &list);

    // Protocol & transaction rules (contract rules 4–10).
    try detectTimeoutNoHeartbeat(arena, events, &list);
    try detectMeterValueGap(arena, sessions, &list);
    try detectInvalidStopReason(arena, events, &list);
    try detectUnexpectedStart(arena, events, &list);
    try detectStatusTransitionViolation(arena, events, &list);
    try detectDiagnosticsFailure(arena, events, &list);
    try detectFirmwareUpdateFailure(arena, events, &list);

    // Timing & anomaly rules (contract rules 11–16).
    try detectSuspiciousSessionDuration(arena, sessions, &list);
    try detectSlowResponse(arena, events, &list);
    try detectHeartbeatIntervalViolation(arena, events, &list);
    try detectMeterValueAnomaly(arena, sessions, &list);
    try detectUnresponsiveCsms(arena, events, &list);
    try detectRepeatedBootNotification(arena, events, &list);

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
// Protocol & transaction rules — constants
// ---------------------------------------------------------------------------

/// OCPP 1.6 default heartbeat interval.
const default_heartbeat_interval_ms: i64 = 60_000;

/// Valid OCPP 1.6 StopTransaction reasons.
const valid_stop_reasons = [_][]const u8{
    "EmergencyStop", "EVDisconnected", "HardReset", "Local",         "Other",        "PowerLoss",
    "Reboot",        "Remote",         "SoftReset", "UnlockCommand", "DeAuthorized",
};

/// Valid OCPP 1.6 connector statuses.
const valid_connector_statuses = [_][]const u8{
    "Available", "Preparing", "Charging",    "SuspendedEVSE", "SuspendedEV",
    "Finishing", "Reserved",  "Unavailable", "Faulted",
};

/// FirmwareStatusNotification statuses that indicate a failed update.
const firmware_failure_statuses = [_][]const u8{
    "DownloadFailed", "DownloadPaused", "InstallFailed", "InstallRebootingFailed",
};

/// The OCPP 1.6 connector state model: allowed successor statuses per status.
/// An unknown predecessor imposes no constraint (matches the contract).
fn isValidTransition(from: []const u8, to: []const u8) bool {
    const allowed: []const []const u8 =
        if (std.mem.eql(u8, from, "Available")) &.{ "Preparing", "Charging", "Reserved", "Unavailable", "Faulted" } else if (std.mem.eql(u8, from, "Preparing")) &.{ "Charging", "Available", "SuspendedEVSE", "Faulted", "Unavailable" } else if (std.mem.eql(u8, from, "Charging")) &.{ "SuspendedEVSE", "SuspendedEV", "Finishing", "Available", "Faulted" } else if (std.mem.eql(u8, from, "SuspendedEVSE")) &.{ "Charging", "Finishing", "Available", "Faulted" } else if (std.mem.eql(u8, from, "SuspendedEV")) &.{ "Charging", "Finishing", "Available", "Faulted" } else if (std.mem.eql(u8, from, "Finishing")) &.{ "Available", "Reserved", "Faulted" } else if (std.mem.eql(u8, from, "Reserved")) &.{ "Available", "Unavailable", "Faulted" } else if (std.mem.eql(u8, from, "Unavailable")) &.{ "Available", "Faulted" } else if (std.mem.eql(u8, from, "Faulted")) &.{ "Unavailable", "Available" } else return true;
    return inList(allowed, to);
}

/// The heartbeat interval (ms) from a BootNotification's response, else default.
fn heartbeatIntervalMs(events: []const Event, boot: Event) i64 {
    for (events) |e| {
        if (e.message_type != .call_result or !std.mem.eql(u8, e.message_id, boot.message_id)) continue;
        if (e.payload != .object) continue;
        const v = e.payload.object.get("interval") orelse continue;
        return switch (v) {
            .integer => |n| n * 1000,
            .float => |f| @intFromFloat(@round(f * 1000.0)),
            else => continue,
        };
    }
    return default_heartbeat_interval_ms;
}

// ---------------------------------------------------------------------------
// Rule 4: TIMEOUT_NO_HEARTBEAT
// ---------------------------------------------------------------------------

/// No Heartbeat within 2× the expected interval after BootNotification — only
/// flagged when the trace actually extends past that threshold.
fn detectTimeoutNoHeartbeat(arena: std.mem.Allocator, events: []const Event, list: *FailureList) !void {
    var boot: ?Event = null;
    for (events) |e| {
        if (isCall(e, "BootNotification")) {
            boot = e;
            break;
        }
    }
    const boot_event = boot orelse return;
    const boot_ts = boot_event.timestamp orelse return;

    const interval_ms = heartbeatIntervalMs(events, boot_event);
    const threshold = boot_ts + interval_ms * 2;

    var has_events_beyond = false;
    for (events) |e| {
        if (e.timestamp) |ts| if (ts > threshold) {
            has_events_beyond = true;
            break;
        };
    }
    if (!has_events_beyond) return;

    var has_heartbeat = false;
    for (events) |e| {
        if (isCall(e, "Heartbeat")) if (e.timestamp) |ts| if (ts <= threshold) {
            has_heartbeat = true;
            break;
        };
    }
    if (has_heartbeat) return;

    const desc = try std.fmt.allocPrint(
        arena,
        "No Heartbeat received within {d}s of BootNotification (expected every {d}s)",
        .{ @divTrunc(interval_ms * 2, 1000), @divTrunc(interval_ms, 1000) },
    );
    try add(arena, list, .timeout_no_heartbeat, desc, try arena.dupe([]const u8, &[_][]const u8{boot_event.id}));
}

// ---------------------------------------------------------------------------
// Rule 5: METER_VALUE_GAP
// ---------------------------------------------------------------------------

/// A completed transaction (Start + Stop) that reported no MeterValues.
fn detectMeterValueGap(arena: std.mem.Allocator, sessions: []const Session, list: *FailureList) !void {
    for (sessions) |session| {
        const tx = session.transaction_id orelse continue;

        var has_start = false;
        var has_stop = false;
        var has_meter = false;
        var start_id: ?[]const u8 = null;
        for (session.events) |e| {
            if (isCall(e, "StartTransaction")) {
                has_start = true;
                if (start_id == null) start_id = e.id;
            }
            if (isCall(e, "StopTransaction")) has_stop = true;
            if (isCall(e, "MeterValues")) has_meter = true;
        }
        if (!has_start or !has_stop or has_meter) continue;

        const desc = try std.fmt.allocPrint(
            arena,
            "Session {s} (transaction {d}) has StartTransaction and StopTransaction but no MeterValues — metering data is missing",
            .{ session.session_id, tx },
        );
        const event_ids = if (start_id) |sid|
            try arena.dupe([]const u8, &[_][]const u8{sid})
        else
            &[_][]const u8{};
        try add(arena, list, .meter_value_gap, desc, event_ids);
    }
}

// ---------------------------------------------------------------------------
// Rule 6: INVALID_STOP_REASON
// ---------------------------------------------------------------------------

/// A StopTransaction whose reason is outside the OCPP 1.6 set.
fn detectInvalidStopReason(arena: std.mem.Allocator, events: []const Event, list: *FailureList) !void {
    for (events) |event| {
        if (!isCall(event, "StopTransaction")) continue;
        const reason = payloadStr(event.payload, "reason") orelse continue;
        if (inList(&valid_stop_reasons, reason)) continue;

        const desc = try std.fmt.allocPrint(
            arena,
            "StopTransaction has invalid stop reason \"{s}\" — not a valid OCPP 1.6 reason code (messageId: {s})",
            .{ reason, event.message_id },
        );
        try add(arena, list, .invalid_stop_reason, desc, try arena.dupe([]const u8, &[_][]const u8{event.id}));
    }
}

// ---------------------------------------------------------------------------
// Rule 7: UNEXPECTED_START
// ---------------------------------------------------------------------------

/// A StartTransaction with no preceding BootNotification or Authorize.
fn detectUnexpectedStart(arena: std.mem.Allocator, events: []const Event, list: *FailureList) !void {
    for (events, 0..) |event, i| {
        if (!isCall(event, "StartTransaction")) continue;

        var has_boot = false;
        var has_authorize = false;
        for (events[0..i]) |e| {
            if (isCall(e, "BootNotification")) has_boot = true;
            if (isCall(e, "Authorize")) has_authorize = true;
        }
        if (has_boot or has_authorize) continue;

        const desc = try std.fmt.allocPrint(
            arena,
            "StartTransaction at event {s} without preceding BootNotification or Authorize — transaction started without proper initialization (messageId: {s})",
            .{ event.id, event.message_id },
        );
        try add(arena, list, .unexpected_start, desc, try arena.dupe([]const u8, &[_][]const u8{event.id}));
    }
}

// ---------------------------------------------------------------------------
// Rule 8: STATUS_TRANSITION_VIOLATION
// ---------------------------------------------------------------------------

const PrevStatus = struct { status: []const u8, event: Event };

/// An illegal connector status transition per the OCPP 1.6 state model.
///
/// Each connector has an independent status machine, so a transition is only
/// valid or invalid relative to the same connector's previous status. Previous
/// status is tracked per connectorId; connectorId 0 refers to the charge point
/// as a whole (OCPP 1.6) and forms its own series, and a missing connectorId is
/// bucketed under "unknown". Comparing statuses across connectors produced
/// false violations on multi-connector stations.
fn detectStatusTransitionViolation(arena: std.mem.Allocator, events: []const Event, list: *FailureList) !void {
    var prev_by_connector = std.StringHashMap(PrevStatus).init(arena);

    for (events) |event| {
        const status = statusNotificationStatus(event) orelse continue;
        if (!inList(&valid_connector_statuses, status)) continue;

        const conn = payloadInt(event.payload, "connectorId");
        const conn_key = if (conn) |c| try std.fmt.allocPrint(arena, "{d}", .{c}) else "unknown";

        if (prev_by_connector.get(conn_key)) |prev| {
            if (!isValidTransition(prev.status, status)) {
                const desc = try std.fmt.allocPrint(
                    arena,
                    "Connector status transition from \"{s}\" to \"{s}\" is not a valid OCPP 1.6 transition (messageId: {s})",
                    .{ prev.status, status, event.message_id },
                );
                try add(arena, list, .status_transition_violation, desc, try ids2(arena, prev.event.id, event.id));
            }
        }

        try prev_by_connector.put(conn_key, .{ .status = status, .event = event });
    }
}

// ---------------------------------------------------------------------------
// Rule 9: DIAGNOSTICS_FAILURE
// ---------------------------------------------------------------------------

/// A DiagnosticsStatusNotification reporting UploadFailed or DiagnosisFailed.
fn detectDiagnosticsFailure(arena: std.mem.Allocator, events: []const Event, list: *FailureList) !void {
    for (events) |event| {
        if (!isCall(event, "DiagnosticsStatusNotification")) continue;
        const status = payloadStr(event.payload, "status") orelse continue;
        if (!std.mem.eql(u8, status, "UploadFailed") and !std.mem.eql(u8, status, "DiagnosisFailed")) continue;

        const desc = try std.fmt.allocPrint(
            arena,
            "DiagnosticsStatusNotification reported failure status \"{s}\" (messageId: {s})",
            .{ status, event.message_id },
        );
        try add(arena, list, .diagnostics_failure, desc, try arena.dupe([]const u8, &[_][]const u8{event.id}));
    }
}

// ---------------------------------------------------------------------------
// Rule 10: FIRMWARE_UPDATE_FAILURE
// ---------------------------------------------------------------------------

/// A FirmwareStatusNotification reporting a failed update.
fn detectFirmwareUpdateFailure(arena: std.mem.Allocator, events: []const Event, list: *FailureList) !void {
    for (events) |event| {
        if (!isCall(event, "FirmwareStatusNotification")) continue;
        const status = payloadStr(event.payload, "status") orelse continue;
        if (!inList(&firmware_failure_statuses, status)) continue;

        const desc = try std.fmt.allocPrint(
            arena,
            "FirmwareStatusNotification reported failure status \"{s}\" (messageId: {s})",
            .{ status, event.message_id },
        );
        try add(arena, list, .firmware_update_failure, desc, try arena.dupe([]const u8, &[_][]const u8{event.id}));
    }
}

// ---------------------------------------------------------------------------
// Timing & anomaly rules — constants
// ---------------------------------------------------------------------------

/// A transaction session shorter than this is suspicious (60 s).
const min_session_duration_ms: i64 = 60_000;

/// A transaction session longer than this is suspicious (24 h).
const max_session_duration_ms: i64 = 24 * 60 * 60 * 1000;

/// A Call→response gap over this is slow (10 s).
const slow_response_threshold_ms: i64 = 10_000;

/// Heartbeat gaps deviating more than this fraction are violations (50%).
const heartbeat_deviation_threshold: f64 = 0.5;

/// Window for counting repeated BootNotifications (5 min).
const repeated_boot_window_ms: i64 = 5 * 60 * 1000;

fn roundedDiv(numerator: i64, denom: i64) i64 {
    return @intFromFloat(@round(@as(f64, @floatFromInt(numerator)) / @as(f64, @floatFromInt(denom))));
}

/// The start/stop transaction event ids of a session (a rule's typical anchors).
fn transactionEventIds(arena: std.mem.Allocator, session: Session) ![]const []const u8 {
    var ids: std.ArrayList([]const u8) = .empty;
    for (session.events) |e| {
        if (isCall(e, "StartTransaction") or isCall(e, "StopTransaction")) try ids.append(arena, e.id);
    }
    return ids.toOwnedSlice(arena);
}

// ---------------------------------------------------------------------------
// Rule 11: SUSPICIOUS_SESSION_DURATION
// ---------------------------------------------------------------------------

/// A transaction session shorter than 60 s or longer than 24 h.
fn detectSuspiciousSessionDuration(arena: std.mem.Allocator, sessions: []const Session, list: *FailureList) !void {
    for (sessions) |session| {
        const tx = session.transaction_id orelse continue;
        const start = session.start_time orelse continue;
        const end = session.end_time orelse continue;
        const duration = end - start;

        if (duration < min_session_duration_ms) {
            const desc = try std.fmt.allocPrint(
                arena,
                "Session {s} (transaction {d}) lasted only {d}ms — suspiciously short session may indicate aborted start or authorization failure",
                .{ session.session_id, tx, duration },
            );
            try add(arena, list, .suspicious_session_duration, desc, try transactionEventIds(arena, session));
        } else if (duration > max_session_duration_ms) {
            const desc = try std.fmt.allocPrint(
                arena,
                "Session {s} (transaction {d}) lasted {d} hours — suspiciously long session may indicate forgotten charging or missing StopTransaction",
                .{ session.session_id, tx, roundedDiv(duration, 60 * 60 * 1000) },
            );
            try add(arena, list, .suspicious_session_duration, desc, try transactionEventIds(arena, session));
        }
    }
}

// ---------------------------------------------------------------------------
// Rule 12: SLOW_RESPONSE
// ---------------------------------------------------------------------------

/// A Call whose matching response arrived more than 10 s later.
fn detectSlowResponse(arena: std.mem.Allocator, events: []const Event, list: *FailureList) !void {
    var response_ts = std.StringHashMap(i64).init(arena);
    defer response_ts.deinit();
    for (events) |e| {
        if (e.message_type == .call_result or e.message_type == .call_error) {
            if (e.timestamp) |ts| try response_ts.put(e.message_id, ts);
        }
    }

    for (events) |call| {
        if (call.message_type != .call) continue;
        const call_ts = call.timestamp orelse continue;
        const resp_ts = response_ts.get(call.message_id) orelse continue; // no response → rule 15

        const gap = resp_ts - call_ts;
        if (gap <= slow_response_threshold_ms) continue;

        const desc = try std.fmt.allocPrint(
            arena,
            "Response to {s} (messageId: {s}) took {d}s — exceeds {d}s threshold",
            .{ call.action orelse "Call", call.message_id, roundedDiv(gap, 1000), @divTrunc(slow_response_threshold_ms, 1000) },
        );
        try add(arena, list, .slow_response, desc, try arena.dupe([]const u8, &[_][]const u8{call.id}));
    }
}

// ---------------------------------------------------------------------------
// Rule 13: HEARTBEAT_INTERVAL_VIOLATION
// ---------------------------------------------------------------------------

/// Consecutive heartbeat gaps deviating more than 50% from the expected interval.
fn detectHeartbeatIntervalViolation(arena: std.mem.Allocator, events: []const Event, list: *FailureList) !void {
    var expected: i64 = default_heartbeat_interval_ms;
    for (events) |e| {
        if (isCall(e, "BootNotification")) {
            expected = heartbeatIntervalMs(events, e);
            break;
        }
    }
    if (expected == 0) return;

    var prev: ?Event = null;
    for (events) |event| {
        if (!isCall(event, "Heartbeat")) continue;
        if (event.timestamp == null) continue;

        if (prev) |p| {
            const gap = event.timestamp.? - p.timestamp.?;
            const deviation = @abs(@as(f64, @floatFromInt(gap - expected))) / @as(f64, @floatFromInt(expected));
            if (deviation > heartbeat_deviation_threshold) {
                const desc = try std.fmt.allocPrint(
                    arena,
                    "Heartbeat interval deviation: {d}s between heartbeats, expected ~{d}s ({d}% deviation)",
                    .{ roundedDiv(gap, 1000), roundedDiv(expected, 1000), @as(i64, @intFromFloat(@round(deviation * 100.0))) },
                );
                try add(arena, list, .heartbeat_interval_violation, desc, try ids2(arena, p.id, event.id));
            }
        }
        prev = event;
    }
}

// ---------------------------------------------------------------------------
// Rule 14: METER_VALUE_ANOMALY
// ---------------------------------------------------------------------------

const Reading = struct { event_id: []const u8, value: f64 };

/// Cumulative energy registers, the only measurands with a monotonic,
/// non-negative invariant per OCPP 1.6 section 7.28.
const cumulative_measurands = [_][]const u8{
    "Energy.Active.Import.Register",
    "Energy.Reactive.Import.Register",
    "Energy.Active.Export.Register",
    "Energy.Reactive.Export.Register",
};

/// OCPP 1.6: when `measurand` is absent it defaults to Energy.Active.Import.Register.
const default_measurand = "Energy.Active.Import.Register";

/// A cumulative energy register that decreases, or is negative, within a
/// transaction.
///
/// Only the cumulative `Energy.*.Register` measurands are monotonic and
/// non-negative (OCPP 1.6 section 7.28). Other measurands (Power, Current,
/// Voltage, Temperature, SoC, ...) legitimately rise and fall, so this rule
/// ignores them. Readings are bucketed by (connectorId, measurand, phase, unit,
/// location) so independent series never contaminate each other's monotonicity,
/// for example a constant Power sample interleaved with a rising Energy
/// register, or two connectors' meters on the same transaction.
fn detectMeterValueAnomaly(arena: std.mem.Allocator, sessions: []const Session, list: *FailureList) !void {
    for (sessions) |session| {
        const tx = session.transaction_id orelse continue;

        // std.StringArrayHashMap was removed in Zig 0.16, so keep insertion
        // order explicitly: `index` maps a bucket key to its slot in `order`.
        var order: std.ArrayList(std.ArrayList(Reading)) = .empty;
        var index = std.StringHashMap(usize).init(arena);
        for (session.events) |event| {
            if (!isCall(event, "MeterValues") or event.payload != .object) continue;
            const conn = payloadInt(event.payload, "connectorId");
            const meter_value = event.payload.object.get("meterValue") orelse continue;
            if (meter_value != .array) continue;
            for (meter_value.array.items) |mv| {
                if (mv != .object) continue;
                const sampled = mv.object.get("sampledValue") orelse continue;
                if (sampled != .array) continue;
                for (sampled.array.items) |sv| {
                    if (sv != .object) continue;
                    const measurand = payloadStr(sv, "measurand") orelse default_measurand;
                    if (!inList(&cumulative_measurands, measurand)) continue;
                    const raw = sv.object.get("value") orelse continue;
                    const value: ?f64 = switch (raw) {
                        .string => |s| std.fmt.parseFloat(f64, s) catch null,
                        .integer => |n| @floatFromInt(n),
                        .float => |f| f,
                        else => null,
                    };
                    const v = value orelse continue;
                    const phase = payloadStr(sv, "phase") orelse "";
                    const unit = payloadStr(sv, "unit") orelse "";
                    const location = payloadStr(sv, "location") orelse "";
                    const key = if (conn) |c|
                        try std.fmt.allocPrint(arena, "{d}|{s}|{s}|{s}|{s}", .{ c, measurand, phase, unit, location })
                    else
                        try std.fmt.allocPrint(arena, "unknown|{s}|{s}|{s}|{s}", .{ measurand, phase, unit, location });
                    const gop = try index.getOrPut(key);
                    if (!gop.found_existing) {
                        gop.value_ptr.* = order.items.len;
                        try order.append(arena, .empty);
                    }
                    try order.items[gop.value_ptr.*].append(arena, .{ .event_id = event.id, .value = v });
                }
            }
        }

        for (order.items) |readings| {
            for (readings.items) |reading| {
                if (reading.value < 0) {
                    const desc = try std.fmt.allocPrint(
                        arena,
                        "Negative meter value detected: {d} in session {s} (transaction {d})",
                        .{ reading.value, session.session_id, tx },
                    );
                    try add(arena, list, .meter_value_anomaly, desc, try arena.dupe([]const u8, &[_][]const u8{reading.event_id}));
                }
            }

            var i: usize = 1;
            while (i < readings.items.len) : (i += 1) {
                const prev = readings.items[i - 1];
                const curr = readings.items[i];
                if (curr.value < prev.value) {
                    const desc = try std.fmt.allocPrint(
                        arena,
                        "Non-monotonic meter reading: value decreased from {d} to {d} in session {s} (transaction {d})",
                        .{ prev.value, curr.value, session.session_id, tx },
                    );
                    try add(arena, list, .meter_value_anomaly, desc, try ids2(arena, prev.event_id, curr.event_id));
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Rule 15: UNRESPONSIVE_CSMS
// ---------------------------------------------------------------------------

/// A Call with no matching CallResult or CallError.
fn detectUnresponsiveCsms(arena: std.mem.Allocator, events: []const Event, list: *FailureList) !void {
    var responded = std.StringHashMap(void).init(arena);
    defer responded.deinit();
    for (events) |e| {
        if (e.message_type == .call_result or e.message_type == .call_error) {
            try responded.put(e.message_id, {});
        }
    }

    for (events) |call| {
        if (call.message_type != .call) continue;
        if (responded.contains(call.message_id)) continue;

        const desc = try std.fmt.allocPrint(
            arena,
            "No response received for {s} Call (messageId: {s}) — CSMS did not respond with CallResult or CallError",
            .{ call.action orelse "Call", call.message_id },
        );
        try add(arena, list, .unresponsive_csms, desc, try arena.dupe([]const u8, &[_][]const u8{call.id}));
    }
}

// ---------------------------------------------------------------------------
// Rule 16: REPEATED_BOOT_NOTIFICATION
// ---------------------------------------------------------------------------

fn lessByTimestamp(_: void, a: Event, b: Event) bool {
    return (a.timestamp orelse 0) < (b.timestamp orelse 0);
}

/// 2+ BootNotification Calls within a 5-minute window.
fn detectRepeatedBootNotification(arena: std.mem.Allocator, events: []const Event, list: *FailureList) !void {
    var boots: std.ArrayList(Event) = .empty;
    defer boots.deinit(arena);
    for (events) |e| {
        if (isCall(e, "BootNotification") and e.timestamp != null) try boots.append(arena, e);
    }
    std.mem.sort(Event, boots.items, {}, lessByTimestamp);

    var i: usize = 0;
    while (i < boots.items.len) : (i += 1) {
        const first = boots.items[i];
        const first_ts = first.timestamp.?;

        var count: usize = 1;
        var j = i + 1;
        while (j < boots.items.len) : (j += 1) {
            if (boots.items[j].timestamp.? - first_ts > repeated_boot_window_ms) break;
            count += 1;
        }

        if (count >= 2) {
            var boot_ids: std.ArrayList([]const u8) = .empty;
            var k = i;
            while (k < j) : (k += 1) try boot_ids.append(arena, boots.items[k].id);
            const window_seconds = roundedDiv(boots.items[j - 1].timestamp.? - first_ts, 1000);
            const desc = try std.fmt.allocPrint(
                arena,
                "{d} BootNotification calls detected within {d}s — station may be rebooting repeatedly or failing startup",
                .{ count, window_seconds },
            );
            try add(arena, list, .repeated_boot_notification, desc, try boot_ids.toOwnedSlice(arena));
            i = j - 1; // continue after this cluster
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

test "TIMEOUT_NO_HEARTBEAT fires only when the trace runs past the threshold" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Boot at 10:00, interval 60s → threshold 10:02; an event at 10:05, no HB.
    const timed_out = try detect(a,
        \\{"events":[
        \\{"timestamp":"2024-01-15T10:00:00.000Z","message":[2,"b1","BootNotification",{"chargePointSerialNumber":"CS-1"}]},
        \\{"timestamp":"2024-01-15T10:00:00.500Z","message":[3,"b1",{"status":"Accepted","interval":60}]},
        \\{"timestamp":"2024-01-15T10:05:00.000Z","message":[2,"n1","StatusNotification",{"connectorId":1,"status":"Available"}]}]}
    );
    try testing.expect(has(timed_out, .timeout_no_heartbeat));

    // A Heartbeat before the threshold clears it.
    const with_hb = try detect(a,
        \\{"events":[
        \\{"timestamp":"2024-01-15T10:00:00.000Z","message":[2,"b1","BootNotification",{"chargePointSerialNumber":"CS-1"}]},
        \\{"timestamp":"2024-01-15T10:00:00.500Z","message":[3,"b1",{"status":"Accepted","interval":60}]},
        \\{"timestamp":"2024-01-15T10:01:00.000Z","message":[2,"h1","Heartbeat",{}]},
        \\{"timestamp":"2024-01-15T10:05:00.000Z","message":[2,"n1","StatusNotification",{"connectorId":1,"status":"Available"}]}]}
    );
    try testing.expect(!has(with_hb, .timeout_no_heartbeat));

    // A trace that ends before the threshold cannot be judged.
    const too_short = try detect(a,
        \\{"events":[
        \\{"timestamp":"2024-01-15T10:00:00.000Z","message":[2,"b1","BootNotification",{"chargePointSerialNumber":"CS-1"}]},
        \\{"timestamp":"2024-01-15T10:00:00.500Z","message":[3,"b1",{"status":"Accepted","interval":60}]}]}
    );
    try testing.expect(!has(too_short, .timeout_no_heartbeat));
}

test "METER_VALUE_GAP fires on a completed transaction with no MeterValues" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const gap = try detect(a,
        \\{"events":[
        \\{"message":[2,"s1","StartTransaction",{"connectorId":1,"meterStart":0}]},
        \\{"message":[3,"s1",{"transactionId":900}]},
        \\{"message":[2,"e1","StopTransaction",{"transactionId":900,"meterStop":10,"reason":"Local"}]},
        \\{"message":[3,"e1",{"idTagInfo":{"status":"Accepted"}}]}]}
    );
    try testing.expect(has(gap, .meter_value_gap));

    const metered = try detect(a,
        \\{"events":[
        \\{"message":[2,"s1","StartTransaction",{"connectorId":1,"meterStart":0}]},
        \\{"message":[3,"s1",{"transactionId":901}]},
        \\{"message":[2,"mv","MeterValues",{"connectorId":1,"transactionId":901,"meterValue":[]}]},
        \\{"message":[3,"mv",{}]},
        \\{"message":[2,"e1","StopTransaction",{"transactionId":901,"meterStop":10,"reason":"Local"}]},
        \\{"message":[3,"e1",{"idTagInfo":{"status":"Accepted"}}]}]}
    );
    try testing.expect(!has(metered, .meter_value_gap));
}

test "INVALID_STOP_REASON fires on a non-spec reason" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const bad = try detect(a,
        \\{"events":[{"message":[2,"e1","StopTransaction",{"transactionId":1,"reason":"Teleported"}]}]}
    );
    try testing.expect(has(bad, .invalid_stop_reason));

    const ok = try detect(a,
        \\{"events":[{"message":[2,"e1","StopTransaction",{"transactionId":1,"reason":"EVDisconnected"}]}]}
    );
    try testing.expect(!has(ok, .invalid_stop_reason));
}

test "UNEXPECTED_START fires without a preceding Boot or Authorize" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const unexpected = try detect(a,
        \\{"events":[{"message":[2,"s1","StartTransaction",{"connectorId":1,"meterStart":0}]}]}
    );
    try testing.expect(has(unexpected, .unexpected_start));

    const initialized = try detect(a,
        \\{"events":[
        \\{"message":[2,"b1","BootNotification",{"chargePointSerialNumber":"CS-1"}]},
        \\{"message":[2,"s1","StartTransaction",{"connectorId":1,"meterStart":0}]}]}
    );
    try testing.expect(!has(initialized, .unexpected_start));
}

test "STATUS_TRANSITION_VIOLATION fires on an illegal transition" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Available → Finishing is not allowed.
    const illegal = try detect(a,
        \\{"events":[
        \\{"message":[2,"n1","StatusNotification",{"connectorId":1,"status":"Available"}]},
        \\{"message":[2,"n2","StatusNotification",{"connectorId":1,"status":"Finishing"}]}]}
    );
    try testing.expect(has(illegal, .status_transition_violation));

    // Available → Preparing is fine.
    const legal = try detect(a,
        \\{"events":[
        \\{"message":[2,"n1","StatusNotification",{"connectorId":1,"status":"Available"}]},
        \\{"message":[2,"n2","StatusNotification",{"connectorId":1,"status":"Preparing"}]}]}
    );
    try testing.expect(!has(legal, .status_transition_violation));
}

test "STATUS_TRANSITION_VIOLATION is tracked per connector, not globally" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Interleaved statuses from two connectors must not be compared to each
    // other: connector 1 goes Charging -> Finishing (valid), connector 2 is
    // Available. Globally that looks like Available -> Finishing (illegal).
    const cross = try detect(a,
        \\{"events":[
        \\{"message":[2,"n1","StatusNotification",{"connectorId":1,"status":"Charging"}]},
        \\{"message":[2,"n2","StatusNotification",{"connectorId":2,"status":"Available"}]},
        \\{"message":[2,"n3","StatusNotification",{"connectorId":1,"status":"Finishing"}]}]}
    );
    try testing.expect(!has(cross, .status_transition_violation));

    // A genuine per-connector violation still fires when interleaved: connector
    // 1 goes Available -> Finishing, which is illegal.
    const genuine = try detect(a,
        \\{"events":[
        \\{"message":[2,"n1","StatusNotification",{"connectorId":1,"status":"Available"}]},
        \\{"message":[2,"n2","StatusNotification",{"connectorId":2,"status":"Charging"}]},
        \\{"message":[2,"n3","StatusNotification",{"connectorId":1,"status":"Finishing"}]}]}
    );
    try testing.expect(has(genuine, .status_transition_violation));

    // connectorId 0 (the whole charge point) is its own series.
    const cp = try detect(a,
        \\{"events":[
        \\{"message":[2,"n1","StatusNotification",{"connectorId":0,"status":"Available"}]},
        \\{"message":[2,"n2","StatusNotification",{"connectorId":1,"status":"Available"}]},
        \\{"message":[2,"n3","StatusNotification",{"connectorId":0,"status":"Finishing"}]}]}
    );
    try testing.expect(has(cp, .status_transition_violation));
}

test "DIAGNOSTICS_FAILURE and FIRMWARE_UPDATE_FAILURE fire on failure statuses" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const diag = try detect(a,
        \\{"events":[{"message":[2,"d1","DiagnosticsStatusNotification",{"status":"UploadFailed"}]}]}
    );
    try testing.expect(has(diag, .diagnostics_failure));
    const diag_ok = try detect(a,
        \\{"events":[{"message":[2,"d1","DiagnosticsStatusNotification",{"status":"Uploaded"}]}]}
    );
    try testing.expect(!has(diag_ok, .diagnostics_failure));

    const fw = try detect(a,
        \\{"events":[{"message":[2,"f1","FirmwareStatusNotification",{"status":"InstallFailed"}]}]}
    );
    try testing.expect(has(fw, .firmware_update_failure));
    const fw_ok = try detect(a,
        \\{"events":[{"message":[2,"f1","FirmwareStatusNotification",{"status":"Installed"}]}]}
    );
    try testing.expect(!has(fw_ok, .firmware_update_failure));
}

test "SUSPICIOUS_SESSION_DURATION fires on a sub-minute transaction" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // ~30s transaction (with MeterValues, to isolate the duration signal).
    const short = try detect(a,
        \\{"events":[
        \\{"timestamp":"2024-01-15T10:00:00.000Z","message":[2,"s1","StartTransaction",{"connectorId":1,"meterStart":0}]},
        \\{"timestamp":"2024-01-15T10:00:00.500Z","message":[3,"s1",{"transactionId":10}]},
        \\{"timestamp":"2024-01-15T10:00:15.000Z","message":[2,"mv","MeterValues",{"connectorId":1,"transactionId":10,"meterValue":[]}]},
        \\{"timestamp":"2024-01-15T10:00:15.500Z","message":[3,"mv",{}]},
        \\{"timestamp":"2024-01-15T10:00:30.000Z","message":[2,"e1","StopTransaction",{"transactionId":10,"meterStop":5,"reason":"Local"}]},
        \\{"timestamp":"2024-01-15T10:00:30.500Z","message":[3,"e1",{"idTagInfo":{"status":"Accepted"}}]}]}
    );
    try testing.expect(has(short, .suspicious_session_duration));

    // A 10-minute transaction is normal.
    const normal = try detect(a,
        \\{"events":[
        \\{"timestamp":"2024-01-15T10:00:00.000Z","message":[2,"s1","StartTransaction",{"connectorId":1,"meterStart":0}]},
        \\{"timestamp":"2024-01-15T10:00:00.500Z","message":[3,"s1",{"transactionId":11}]},
        \\{"timestamp":"2024-01-15T10:05:00.000Z","message":[2,"mv","MeterValues",{"connectorId":1,"transactionId":11,"meterValue":[]}]},
        \\{"timestamp":"2024-01-15T10:05:00.500Z","message":[3,"mv",{}]},
        \\{"timestamp":"2024-01-15T10:10:00.000Z","message":[2,"e1","StopTransaction",{"transactionId":11,"meterStop":5,"reason":"Local"}]},
        \\{"timestamp":"2024-01-15T10:10:00.500Z","message":[3,"e1",{"idTagInfo":{"status":"Accepted"}}]}]}
    );
    try testing.expect(!has(normal, .suspicious_session_duration));
}

test "SLOW_RESPONSE fires when a response lags past 10s" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const slow = try detect(a,
        \\{"events":[
        \\{"timestamp":"2024-01-15T10:00:00.000Z","message":[2,"h1","Heartbeat",{}]},
        \\{"timestamp":"2024-01-15T10:00:15.000Z","message":[3,"h1",{}]}]}
    );
    try testing.expect(has(slow, .slow_response));

    const fast = try detect(a,
        \\{"events":[
        \\{"timestamp":"2024-01-15T10:00:00.000Z","message":[2,"h1","Heartbeat",{}]},
        \\{"timestamp":"2024-01-15T10:00:02.000Z","message":[3,"h1",{}]}]}
    );
    try testing.expect(!has(fast, .slow_response));
}

test "HEARTBEAT_INTERVAL_VIOLATION fires on a >50% gap deviation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Default expected interval 60s; a 150s gap deviates 150%.
    const irregular = try detect(a,
        \\{"events":[
        \\{"timestamp":"2024-01-15T10:00:00.000Z","message":[2,"h1","Heartbeat",{}]},
        \\{"timestamp":"2024-01-15T10:00:00.500Z","message":[3,"h1",{}]},
        \\{"timestamp":"2024-01-15T10:02:30.000Z","message":[2,"h2","Heartbeat",{}]},
        \\{"timestamp":"2024-01-15T10:02:30.500Z","message":[3,"h2",{}]}]}
    );
    try testing.expect(has(irregular, .heartbeat_interval_violation));

    // A steady 60s cadence is fine.
    const steady = try detect(a,
        \\{"events":[
        \\{"timestamp":"2024-01-15T10:00:00.000Z","message":[2,"h1","Heartbeat",{}]},
        \\{"timestamp":"2024-01-15T10:00:00.500Z","message":[3,"h1",{}]},
        \\{"timestamp":"2024-01-15T10:01:00.000Z","message":[2,"h2","Heartbeat",{}]},
        \\{"timestamp":"2024-01-15T10:01:00.500Z","message":[3,"h2",{}]}]}
    );
    try testing.expect(!has(steady, .heartbeat_interval_violation));
}

test "METER_VALUE_ANOMALY fires on a decreasing reading" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const decreasing = try detect(a,
        \\{"events":[
        \\{"message":[2,"s1","StartTransaction",{"connectorId":1,"meterStart":0}]},
        \\{"message":[3,"s1",{"transactionId":20}]},
        \\{"message":[2,"mv1","MeterValues",{"connectorId":1,"transactionId":20,"meterValue":[{"sampledValue":[{"value":"5000"}]}]}]},
        \\{"message":[3,"mv1",{}]},
        \\{"message":[2,"mv2","MeterValues",{"connectorId":1,"transactionId":20,"meterValue":[{"sampledValue":[{"value":"3000"}]}]}]},
        \\{"message":[3,"mv2",{}]}]}
    );
    try testing.expect(has(decreasing, .meter_value_anomaly));

    const increasing = try detect(a,
        \\{"events":[
        \\{"message":[2,"s1","StartTransaction",{"connectorId":1,"meterStart":0}]},
        \\{"message":[3,"s1",{"transactionId":21}]},
        \\{"message":[2,"mv1","MeterValues",{"connectorId":1,"transactionId":21,"meterValue":[{"sampledValue":[{"value":"5000"}]}]}]},
        \\{"message":[3,"mv1",{}]},
        \\{"message":[2,"mv2","MeterValues",{"connectorId":1,"transactionId":21,"meterValue":[{"sampledValue":[{"value":"10000"}]}]}]},
        \\{"message":[3,"mv2",{}]}]}
    );
    try testing.expect(!has(increasing, .meter_value_anomaly));
}

test "METER_VALUE_ANOMALY ignores non-cumulative measurands, checks energy per bucket" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A rising Energy register interleaved with a constant Power sample must not
    // fire: flattening the two series is the bug this guards against.
    const rising = try detect(a,
        \\{"events":[
        \\{"message":[2,"s1","StartTransaction",{"connectorId":1,"meterStart":0}]},
        \\{"message":[3,"s1",{"transactionId":30}]},
        \\{"message":[2,"mv1","MeterValues",{"connectorId":1,"transactionId":30,"meterValue":[{"sampledValue":[{"measurand":"Energy.Active.Import.Register","value":"600"},{"measurand":"Power.Active.Import","value":"3000"}]}]}]},
        \\{"message":[3,"mv1",{}]},
        \\{"message":[2,"mv2","MeterValues",{"connectorId":1,"transactionId":30,"meterValue":[{"sampledValue":[{"measurand":"Energy.Active.Import.Register","value":"625"},{"measurand":"Power.Active.Import","value":"3000"}]}]}]},
        \\{"message":[3,"mv2",{}]}]}
    );
    try testing.expect(!has(rising, .meter_value_anomaly));

    // A genuinely decreasing Energy register still fires despite the Power sample.
    const decreasing = try detect(a,
        \\{"events":[
        \\{"message":[2,"s1","StartTransaction",{"connectorId":1,"meterStart":0}]},
        \\{"message":[3,"s1",{"transactionId":31}]},
        \\{"message":[2,"mv1","MeterValues",{"connectorId":1,"transactionId":31,"meterValue":[{"sampledValue":[{"measurand":"Energy.Active.Import.Register","value":"600"},{"measurand":"Power.Active.Import","value":"3000"}]}]}]},
        \\{"message":[3,"mv1",{}]},
        \\{"message":[2,"mv2","MeterValues",{"connectorId":1,"transactionId":31,"meterValue":[{"sampledValue":[{"measurand":"Energy.Active.Import.Register","value":"500"},{"measurand":"Power.Active.Import","value":"3000"}]}]}]},
        \\{"message":[3,"mv2",{}]}]}
    );
    try testing.expect(has(decreasing, .meter_value_anomaly));
}

test "UNRESPONSIVE_CSMS fires on an unanswered Call" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const dropped = try detect(a,
        \\{"events":[{"message":[2,"h1","Heartbeat",{}]}]}
    );
    try testing.expect(has(dropped, .unresponsive_csms));

    const answered = try detect(a,
        \\{"events":[{"message":[2,"h1","Heartbeat",{}]},{"message":[3,"h1",{}]}]}
    );
    try testing.expect(!has(answered, .unresponsive_csms));
}

test "REPEATED_BOOT_NOTIFICATION fires on two boots inside the window" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Two boots 2 minutes apart (within the 5-minute window).
    const rebooting = try detect(a,
        \\{"events":[
        \\{"timestamp":"2024-01-15T10:00:00.000Z","message":[2,"b1","BootNotification",{"chargePointSerialNumber":"CS-1"}]},
        \\{"timestamp":"2024-01-15T10:00:00.500Z","message":[3,"b1",{"status":"Accepted","interval":300}]},
        \\{"timestamp":"2024-01-15T10:02:00.000Z","message":[2,"b2","BootNotification",{"chargePointSerialNumber":"CS-1"}]},
        \\{"timestamp":"2024-01-15T10:02:00.500Z","message":[3,"b2",{"status":"Accepted","interval":300}]}]}
    );
    try testing.expect(has(rebooting, .repeated_boot_notification));

    // Two boots 10 minutes apart are not clustered.
    const spaced = try detect(a,
        \\{"events":[
        \\{"timestamp":"2024-01-15T10:00:00.000Z","message":[2,"b1","BootNotification",{"chargePointSerialNumber":"CS-1"}]},
        \\{"timestamp":"2024-01-15T10:00:00.500Z","message":[3,"b1",{"status":"Accepted","interval":300}]},
        \\{"timestamp":"2024-01-15T10:10:00.000Z","message":[2,"b2","BootNotification",{"chargePointSerialNumber":"CS-1"}]},
        \\{"timestamp":"2024-01-15T10:10:00.500Z","message":[3,"b2",{"status":"Accepted","interval":300}]}]}
    );
    try testing.expect(!has(spaced, .repeated_boot_notification));
}
