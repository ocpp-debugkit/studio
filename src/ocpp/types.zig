//! Canonical, headless data model for the OCPP engine.
//!
//! Mirrors the toolkit's `core/types.ts` model — the shared conformance
//! contract — adapted to idiomatic Zig. Arbitrary OCPP payloads and raw message
//! arrays are carried as `std.json.Value` behind a version-tagged decode seam
//! (ADR-0005), so OCPP 2.0.1 lands additively rather than as a rewrite.
//!
//! Lifetime: parsed events borrow from a single parse arena (see parser.zig).
//! The `[]const u8` fields and `std.json.Value` payloads point into arena-owned
//! memory and stay valid until that arena is freed.

const std = @import("std");

// ---------------------------------------------------------------------------
// Primitives
// ---------------------------------------------------------------------------

/// Direction of an OCPP message. Inferred when a trace omits it (normalizer.zig).
pub const Direction = enum {
    cs_to_csms,
    csms_to_cs,
    unknown,

    pub fn toWire(self: Direction) []const u8 {
        return switch (self) {
            .cs_to_csms => "CS_TO_CSMS",
            .csms_to_cs => "CSMS_TO_CS",
            .unknown => "UNKNOWN",
        };
    }

    /// Parse an explicit `direction` field from trace input. Null if unrecognized.
    pub fn fromWire(s: []const u8) ?Direction {
        if (std.mem.eql(u8, s, "CS_TO_CSMS")) return .cs_to_csms;
        if (std.mem.eql(u8, s, "CSMS_TO_CS")) return .csms_to_cs;
        if (std.mem.eql(u8, s, "UNKNOWN")) return .unknown;
        return null;
    }
};

/// OCPP 1.6 JSON message type, keyed by the leading MessageTypeId.
pub const MessageType = enum {
    /// `[2, UniqueId, Action, Payload]`
    call,
    /// `[3, UniqueId, Payload]`
    call_result,
    /// `[4, UniqueId, ErrorCode, ErrorDescription, ErrorDetails]`
    call_error,

    pub fn toWire(self: MessageType) []const u8 {
        return switch (self) {
            .call => "Call",
            .call_result => "CallResult",
            .call_error => "CallError",
        };
    }

    /// The wire MessageTypeId (2/3/4).
    pub fn typeId(self: MessageType) u8 {
        return switch (self) {
            .call => 2,
            .call_result => 3,
            .call_error => 4,
        };
    }

    /// Classify a raw MessageTypeId. Null for anything outside {2, 3, 4}.
    /// Takes `i64` because it comes straight off a parsed JSON integer.
    pub fn fromTypeId(id: i64) ?MessageType {
        return switch (id) {
            2 => .call,
            3 => .call_result,
            4 => .call_error,
            else => null,
        };
    }
};

/// Lifecycle status of a correlated charging session.
pub const Status = enum {
    active,
    completed,
    aborted,

    pub fn toWire(self: Status) []const u8 {
        return switch (self) {
            .active => "active",
            .completed => "completed",
            .aborted => "aborted",
        };
    }
};

// ---------------------------------------------------------------------------
// Value boundary (ADR-0005)
// ---------------------------------------------------------------------------

/// A raw OCPP 1.6 JSON message, carried as a JSON array value:
/// `[MessageTypeId, UniqueId, ...]`. Message-field extraction lives in
/// normalizer.zig so this stays a plain value at the boundary.
pub const RawMessage = std.json.Value;

// ---------------------------------------------------------------------------
// Event model
// ---------------------------------------------------------------------------

/// A trace event entry as it appears in a trace file, before normalization.
pub const TraceEventInput = struct {
    /// Raw timestamp: a JSON string (ISO 8601) or number (epoch s/ms).
    /// `.null` when the trace omits it.
    timestamp: std.json.Value = .null,
    /// Explicit direction if the trace provided one; inferred when null.
    direction: ?Direction = null,
    /// Raw OCPP message array.
    message: RawMessage,
};

/// The canonical normalized event used throughout the engine.
pub const Event = struct {
    /// Generated event ID (`evt-0001`), sequential and stable within a parse.
    id: []const u8,
    /// OCPP UniqueId from the message array.
    message_id: []const u8,
    /// Normalized timestamp in epoch milliseconds; null if missing/invalid.
    timestamp: ?i64,
    direction: Direction,
    message_type: MessageType,
    /// OCPP action name; present only for Call messages.
    action: ?[]const u8,
    /// OCPP payload object (`.null` when none).
    payload: std.json.Value,
    /// Error code; present only for CallError messages.
    error_code: ?[]const u8,
    /// Error description; present only for CallError messages.
    error_description: ?[]const u8,
    /// The original raw OCPP message array, unmodified.
    raw_message: RawMessage,
};

// ---------------------------------------------------------------------------
// Trace model
// ---------------------------------------------------------------------------

/// Optional metadata block of the JSON object trace format.
pub const TraceMetadata = struct {
    station_id: ?[]const u8 = null,
    ocpp_version: ?[]const u8 = null,
    source: ?[]const u8 = null,
    description: ?[]const u8 = null,
};

/// The JSON object trace format: `{ traceId?, metadata?, events[] }`.
pub const Trace = struct {
    trace_id: ?[]const u8 = null,
    metadata: ?TraceMetadata = null,
    events: []TraceEventInput,
};

// ---------------------------------------------------------------------------
// Parse result
// ---------------------------------------------------------------------------

/// A warning produced when an individual event is malformed. Parsing continues;
/// only structural failures abort (see parser.zig).
pub const ParseWarning = struct {
    index: usize,
    message: []const u8,
    raw_input: ?[]const u8 = null,
};

/// Result of parsing a trace. The slices borrow from the arena passed to
/// `parseTrace`; the caller owns that arena's lifetime.
pub const ParseResult = struct {
    events: []Event,
    warnings: []ParseWarning,
};

// ---------------------------------------------------------------------------
// Session model
// ---------------------------------------------------------------------------

/// A logical charging session derived from trace events (see timeline.zig).
pub const Session = struct {
    session_id: []const u8,
    station_id: []const u8,
    connector_id: ?i64,
    transaction_id: ?i64,
    start_time: ?i64,
    end_time: ?i64,
    events: []Event,
    status: Status,
};

// ---------------------------------------------------------------------------
// Failure detection model
// ---------------------------------------------------------------------------

/// Severity of a detected failure.
pub const FailureSeverity = enum {
    critical,
    warning,
    info,

    pub fn toWire(self: FailureSeverity) []const u8 {
        return switch (self) {
            .critical => "critical",
            .warning => "warning",
            .info => "info",
        };
    }
};

/// The OCPP 1.6J failure taxonomy — the 16 detection-rule codes (see
/// detection.zig). Wire strings match the toolkit's `FailureCode` union.
pub const FailureCode = enum {
    failed_authorization,
    connector_fault,
    station_offline_during_session,
    timeout_no_heartbeat,
    meter_value_gap,
    invalid_stop_reason,
    unexpected_start,
    status_transition_violation,
    diagnostics_failure,
    firmware_update_failure,
    suspicious_session_duration,
    slow_response,
    heartbeat_interval_violation,
    meter_value_anomaly,
    unresponsive_csms,
    repeated_boot_notification,

    pub fn toWire(self: FailureCode) []const u8 {
        return switch (self) {
            .failed_authorization => "FAILED_AUTHORIZATION",
            .connector_fault => "CONNECTOR_FAULT",
            .station_offline_during_session => "STATION_OFFLINE_DURING_SESSION",
            .timeout_no_heartbeat => "TIMEOUT_NO_HEARTBEAT",
            .meter_value_gap => "METER_VALUE_GAP",
            .invalid_stop_reason => "INVALID_STOP_REASON",
            .unexpected_start => "UNEXPECTED_START",
            .status_transition_violation => "STATUS_TRANSITION_VIOLATION",
            .diagnostics_failure => "DIAGNOSTICS_FAILURE",
            .firmware_update_failure => "FIRMWARE_UPDATE_FAILURE",
            .suspicious_session_duration => "SUSPICIOUS_SESSION_DURATION",
            .slow_response => "SLOW_RESPONSE",
            .heartbeat_interval_violation => "HEARTBEAT_INTERVAL_VIOLATION",
            .meter_value_anomaly => "METER_VALUE_ANOMALY",
            .unresponsive_csms => "UNRESPONSIVE_CSMS",
            .repeated_boot_notification => "REPEATED_BOOT_NOTIFICATION",
        };
    }
};

/// A detected failure in a trace.
pub const Failure = struct {
    code: FailureCode,
    description: []const u8,
    severity: FailureSeverity,
    /// Event ids implicated in the failure.
    event_ids: []const []const u8,
    /// Suggested remediation steps.
    suggested_steps: []const []const u8,
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Direction wire encoding round-trips" {
    try testing.expectEqualStrings("CS_TO_CSMS", Direction.cs_to_csms.toWire());
    try testing.expectEqualStrings("CSMS_TO_CS", Direction.csms_to_cs.toWire());
    try testing.expectEqualStrings("UNKNOWN", Direction.unknown.toWire());

    try testing.expectEqual(Direction.cs_to_csms, Direction.fromWire("CS_TO_CSMS").?);
    try testing.expectEqual(Direction.csms_to_cs, Direction.fromWire("CSMS_TO_CS").?);
    try testing.expectEqual(Direction.unknown, Direction.fromWire("UNKNOWN").?);
    try testing.expectEqual(@as(?Direction, null), Direction.fromWire("sideways"));
}

test "MessageType maps to wire strings and type ids" {
    try testing.expectEqualStrings("Call", MessageType.call.toWire());
    try testing.expectEqualStrings("CallResult", MessageType.call_result.toWire());
    try testing.expectEqualStrings("CallError", MessageType.call_error.toWire());

    try testing.expectEqual(@as(u8, 2), MessageType.call.typeId());
    try testing.expectEqual(@as(u8, 3), MessageType.call_result.typeId());
    try testing.expectEqual(@as(u8, 4), MessageType.call_error.typeId());

    try testing.expectEqual(MessageType.call, MessageType.fromTypeId(2).?);
    try testing.expectEqual(MessageType.call_result, MessageType.fromTypeId(3).?);
    try testing.expectEqual(MessageType.call_error, MessageType.fromTypeId(4).?);
    try testing.expectEqual(@as(?MessageType, null), MessageType.fromTypeId(1));
    try testing.expectEqual(@as(?MessageType, null), MessageType.fromTypeId(99));
}

test "Status maps to wire strings" {
    try testing.expectEqualStrings("active", Status.active.toWire());
    try testing.expectEqualStrings("completed", Status.completed.toWire());
    try testing.expectEqualStrings("aborted", Status.aborted.toWire());
}

test "Failure taxonomy encodes to contract wire strings" {
    try testing.expectEqualStrings("FAILED_AUTHORIZATION", FailureCode.failed_authorization.toWire());
    try testing.expectEqualStrings("REPEATED_BOOT_NOTIFICATION", FailureCode.repeated_boot_notification.toWire());
    try testing.expectEqualStrings("critical", FailureSeverity.critical.toWire());
    try testing.expectEqualStrings("info", FailureSeverity.info.toWire());
}

test "the model holds a parsed OCPP message end to end" {
    // A Call carrying a JSON payload, parsed into an arena, threaded through the
    // canonical Event shape — the boundary the whole engine is built on.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const raw = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        \\[2,"msg-001","BootNotification",{"chargePointVendor":"Synthetic"}]
    ,
        .{},
    );

    const event = Event{
        .id = "evt-0001",
        .message_id = raw.array.items[1].string,
        .timestamp = 1705312200000,
        .direction = .cs_to_csms,
        .message_type = .call,
        .action = raw.array.items[2].string,
        .payload = raw.array.items[3],
        .error_code = null,
        .error_description = null,
        .raw_message = raw,
    };

    try testing.expectEqualStrings("msg-001", event.message_id);
    try testing.expectEqualStrings("BootNotification", event.action.?);
    try testing.expectEqual(MessageType.call, event.message_type);
    try testing.expectEqualStrings(
        "Synthetic",
        event.payload.object.get("chargePointVendor").?.string,
    );
}
