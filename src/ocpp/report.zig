//! Trace report generation — Markdown + HTML.
//!
//! Mirrors the toolkit's `reporter/{markdown,html}.ts`: the same six sections
//! (header, session overview, timeline summary, failures, suggested next steps,
//! event appendix) over the same `AnalysisResult`. Pure and headless — the
//! caller owns the allocator and any file I/O; the module never touches disk.
//!
//! Two deliberate departures from the toolkit, both hardening the
//! untrusted-input path (trace content is untrusted):
//!   * **Escaping on both paths.** The toolkit escapes only its HTML report;
//!     its Markdown report interpolates raw. Here every trace-derived value is
//!     escaped — HTML entities for HTML, table/line-structural chars for
//!     Markdown — so a hostile payload can't inject markup or break a table.
//!   * **Bounded list sections.** A trusted-ingestion trace (ADR-0007) can hold
//!     millions of events; the rendered lists are capped (the header still
//!     reports the true totals) so the document size stays bounded.

const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Buf = std.ArrayList(u8);

/// The analysis result a report renders. Mirrors the toolkit's
/// `reporter/types.ts` `AnalysisResult`.
pub const AnalysisResult = struct {
    events: []const types.Event,
    sessions: []const types.Session,
    failures: []const types.Failure,
    summaries: []const types.SessionSummary,
    warnings: []const types.ParseWarning,
    metadata: ?types.TraceMetadata = null,
};

/// Row/box caps for the rendered list sections. The header reports true totals;
/// only the rendered lists truncate, each with a trailing note.
const max_appendix_rows = 1000;
const max_listed_sessions = 500;
const max_listed_failures = 500;

// ---------------------------------------------------------------------------
// Small append helpers
// ---------------------------------------------------------------------------

fn app(buf: *Buf, gpa: Allocator, bytes: []const u8) !void {
    try buf.appendSlice(gpa, bytes);
}

fn appf(buf: *Buf, gpa: Allocator, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(gpa, fmt, args);
    defer gpa.free(s);
    try buf.appendSlice(gpa, s);
}

/// Append `s` with HTML special characters escaped (mirrors `escapeHtml` in
/// `reporter/html.ts`).
fn htmlEscaped(buf: *Buf, gpa: Allocator, s: []const u8) !void {
    for (s) |c| switch (c) {
        '&' => try app(buf, gpa, "&amp;"),
        '<' => try app(buf, gpa, "&lt;"),
        '>' => try app(buf, gpa, "&gt;"),
        '"' => try app(buf, gpa, "&quot;"),
        '\'' => try app(buf, gpa, "&#39;"),
        else => try buf.append(gpa, c),
    };
}

/// Append `s` safe for a Markdown table cell / single line: pipes are escaped
/// and control characters collapse to spaces, so trace content can't break the
/// table or line structure.
fn mdEscaped(buf: *Buf, gpa: Allocator, s: []const u8) !void {
    for (s) |c| switch (c) {
        '|' => try app(buf, gpa, "\\|"),
        '\n', '\r', '\t' => try buf.append(gpa, ' '),
        else => try buf.append(gpa, c),
    };
}

// ---------------------------------------------------------------------------
// Formatters (shared by both renderers)
// ---------------------------------------------------------------------------

/// Human-readable duration, mirroring the toolkit's `formatDuration`.
fn writeDuration(buf: *Buf, gpa: Allocator, ms: ?i64) !void {
    const v = ms orelse return app(buf, gpa, "Unknown");
    if (v < 1000) return appf(buf, gpa, "{d}ms", .{v});
    const seconds = @divFloor(v, 1000);
    if (seconds < 60) return appf(buf, gpa, "{d}s", .{seconds});
    const minutes = @divFloor(seconds, 60);
    const rem_s = @mod(seconds, 60);
    if (minutes < 60) return appf(buf, gpa, "{d}m {d}s", .{ minutes, rem_s });
    const hours = @divFloor(minutes, 60);
    const rem_m = @mod(minutes, 60);
    return appf(buf, gpa, "{d}h {d}m", .{ hours, rem_m });
}

/// Epoch-millisecond timestamp as ISO 8601 UTC (`YYYY-MM-DDTHH:MM:SS.sssZ`),
/// matching the toolkit's `new Date(ms).toISOString()`. Pre-1970 instants
/// (negative epoch) are not produced by the normalizer for real traces; they
/// fall back to the raw integer rather than panic.
fn writeTimestamp(buf: *Buf, gpa: Allocator, ms: ?i64) !void {
    const v = ms orelse return app(buf, gpa, "Unknown");
    if (v < 0) return appf(buf, gpa, "{d}", .{v});

    const total_seconds: u64 = @intCast(@divFloor(v, 1000));
    const millis: u64 = @intCast(@mod(v, 1000));
    const es = std.time.epoch.EpochSeconds{ .secs = total_seconds };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();

    try appf(buf, gpa, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        yd.year,
        md.month.numeric(),
        @as(u32, md.day_index) + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
        millis,
    });
}

fn severityEmoji(sev: types.FailureSeverity) []const u8 {
    return switch (sev) {
        .critical => "🔴",
        .warning => "🟡",
        .info => "🔵",
    };
}

fn severityClass(sev: types.FailureSeverity) []const u8 {
    return switch (sev) {
        .critical => "severity-critical",
        .warning => "severity-warning",
        .info => "severity-info",
    };
}

/// Session duration in ms, or null when either bound is unknown.
fn sessionDuration(s: types.Session) ?i64 {
    if (s.start_time != null and s.end_time != null) return s.end_time.? - s.start_time.?;
    return null;
}

// ---------------------------------------------------------------------------
// Markdown report
// ---------------------------------------------------------------------------

/// Generate a Markdown report. Caller owns the returned slice.
pub fn generateMarkdownReport(gpa: Allocator, result: AnalysisResult) ![]u8 {
    var buf: Buf = .empty;
    errdefer buf.deinit(gpa);

    try mdHeader(&buf, gpa, result);
    try app(&buf, gpa, "\n\n");
    try mdSessionOverview(&buf, gpa, result);
    try app(&buf, gpa, "\n\n");
    try mdTimelineSummary(&buf, gpa, result);
    try app(&buf, gpa, "\n\n");
    try mdFailures(&buf, gpa, result);
    try app(&buf, gpa, "\n\n");
    try mdSuggestedSteps(&buf, gpa, result);
    try app(&buf, gpa, "\n\n");
    try mdEventAppendix(&buf, gpa, result);
    try app(&buf, gpa, "\n");

    return buf.toOwnedSlice(gpa);
}

fn mdMetaRow(buf: *Buf, gpa: Allocator, label: []const u8, value: []const u8) !void {
    try appf(buf, gpa, "**{s}:** ", .{label});
    try mdEscaped(buf, gpa, value);
    try app(buf, gpa, "\n");
}

fn mdHeader(buf: *Buf, gpa: Allocator, result: AnalysisResult) !void {
    try app(buf, gpa, "# OCPP DebugKit — Trace Analysis Report\n\n");

    if (result.metadata) |m| {
        if (m.station_id) |x| try mdMetaRow(buf, gpa, "Station", x);
        if (m.ocpp_version) |x| try mdMetaRow(buf, gpa, "OCPP Version", x);
        if (m.source) |x| try mdMetaRow(buf, gpa, "Source", x);
        if (m.description) |x| try mdMetaRow(buf, gpa, "Description", x);
    }

    try appf(buf, gpa, "**Events:** {d}\n**Sessions:** {d}\n**Failures:** {d}\n**Warnings:** {d}", .{
        result.events.len,
        result.sessions.len,
        result.failures.len,
        result.warnings.len,
    });

    if (result.warnings.len > 0) {
        try app(buf, gpa, "\n\n## Parse Warnings\n\n");
        for (result.warnings) |w| {
            try app(buf, gpa, "- ");
            try mdEscaped(buf, gpa, w.message);
            try app(buf, gpa, "\n");
        }
    }
}

fn mdSessionOverview(buf: *Buf, gpa: Allocator, result: AnalysisResult) !void {
    try app(buf, gpa, "## Session Overview\n\n");
    if (result.sessions.len == 0) {
        try app(buf, gpa, "No sessions detected.\n");
        return;
    }

    try app(buf, gpa, "| Session | Station | Connector | Transaction | Start | End | Duration | Status |\n");
    try app(buf, gpa, "|---------|---------|-----------|-------------|-------|-----|----------|--------|\n");

    const shown = @min(result.sessions.len, max_listed_sessions);
    for (result.sessions[0..shown]) |session| {
        try app(buf, gpa, "| ");
        try mdEscaped(buf, gpa, session.session_id);
        try app(buf, gpa, " | ");
        try mdEscaped(buf, gpa, session.station_id);
        try app(buf, gpa, " | ");
        try mdOptInt(buf, gpa, session.connector_id);
        try app(buf, gpa, " | ");
        try mdOptInt(buf, gpa, session.transaction_id);
        try app(buf, gpa, " | ");
        try writeTimestamp(buf, gpa, session.start_time);
        try app(buf, gpa, " | ");
        try writeTimestamp(buf, gpa, session.end_time);
        try app(buf, gpa, " | ");
        try writeDuration(buf, gpa, sessionDuration(session));
        try app(buf, gpa, " | ");
        try app(buf, gpa, session.status.toWire());
        try app(buf, gpa, " |\n");
    }
    try mdTruncationNote(buf, gpa, result.sessions.len, shown, "sessions");
}

fn mdOptInt(buf: *Buf, gpa: Allocator, v: ?i64) !void {
    if (v) |n| try appf(buf, gpa, "{d}", .{n}) else try app(buf, gpa, "-");
}

fn mdTimelineSummary(buf: *Buf, gpa: Allocator, result: AnalysisResult) !void {
    try app(buf, gpa, "## Timeline Summary\n\n");
    if (result.summaries.len == 0) {
        try app(buf, gpa, "No sessions to summarize.\n");
        return;
    }

    const shown = @min(result.summaries.len, max_listed_sessions);
    for (result.summaries[0..shown]) |s| {
        try app(buf, gpa, "### ");
        try mdEscaped(buf, gpa, s.session_id);
        try app(buf, gpa, "\n\n");
        try appf(buf, gpa, "- **Events:** {d}\n", .{s.event_count});
        try app(buf, gpa, "- **Duration:** ");
        try writeDuration(buf, gpa, s.duration_ms);
        try app(buf, gpa, "\n");
        try appf(buf, gpa, "- **Failures:** {d}\n", .{s.failure_count});
        try app(buf, gpa, "- **Action Sequence:** ");
        try mdActionSequence(buf, gpa, s.action_sequence);
        try app(buf, gpa, "\n\n");
    }
    try mdTruncationNote(buf, gpa, result.summaries.len, shown, "sessions");
}

fn mdActionSequence(buf: *Buf, gpa: Allocator, actions: []const []const u8) !void {
    if (actions.len == 0) {
        try app(buf, gpa, "None");
        return;
    }
    for (actions, 0..) |a, i| {
        if (i > 0) try app(buf, gpa, " → ");
        try mdEscaped(buf, gpa, a);
    }
}

fn mdFailures(buf: *Buf, gpa: Allocator, result: AnalysisResult) !void {
    try app(buf, gpa, "## Failures\n\n");
    if (result.failures.len == 0) {
        try app(buf, gpa, "No failures detected. ✅\n");
        return;
    }

    const shown = @min(result.failures.len, max_listed_failures);
    for (result.failures[0..shown]) |f| {
        try appf(buf, gpa, "### {s} {s}\n\n", .{ severityEmoji(f.severity), f.code.toWire() });
        try appf(buf, gpa, "**Severity:** {s}\n", .{f.severity.toWire()});
        try app(buf, gpa, "**Description:** ");
        try mdEscaped(buf, gpa, f.description);
        try app(buf, gpa, "\n**Events:** ");
        for (f.event_ids, 0..) |id, i| {
            if (i > 0) try app(buf, gpa, ", ");
            try mdEscaped(buf, gpa, id);
        }
        try app(buf, gpa, "\n\n**Suggested Steps:**\n\n");
        for (f.suggested_steps) |step| {
            try app(buf, gpa, "1. ");
            try mdEscaped(buf, gpa, step);
            try app(buf, gpa, "\n");
        }
        try app(buf, gpa, "\n");
    }
    try mdTruncationNote(buf, gpa, result.failures.len, shown, "failures");
}

fn mdSuggestedSteps(buf: *Buf, gpa: Allocator, result: AnalysisResult) !void {
    try app(buf, gpa, "## Suggested Next Steps\n\n");
    if (result.failures.len == 0) {
        try app(buf, gpa, "No issues detected. The trace appears to represent a normal charging session.\n");
        return;
    }

    var seen = std.StringHashMap(void).init(gpa);
    defer seen.deinit();
    var i: usize = 1;
    for (result.failures) |f| {
        for (f.suggested_steps) |step| {
            const gop = try seen.getOrPut(step);
            if (gop.found_existing) continue;
            try appf(buf, gpa, "{d}. ", .{i});
            try mdEscaped(buf, gpa, step);
            try app(buf, gpa, "\n");
            i += 1;
        }
    }
}

fn mdEventAppendix(buf: *Buf, gpa: Allocator, result: AnalysisResult) !void {
    try app(buf, gpa, "## Event Appendix\n\n");
    if (result.events.len == 0) {
        try app(buf, gpa, "No events to display.\n");
        return;
    }

    try app(buf, gpa, "| ID | Timestamp | Direction | Type | Action | MessageId |\n");
    try app(buf, gpa, "|----|-----------|-----------|------|--------|-----------|\n");

    const shown = @min(result.events.len, max_appendix_rows);
    for (result.events[0..shown]) |e| {
        try app(buf, gpa, "| ");
        try mdEscaped(buf, gpa, e.id);
        try app(buf, gpa, " | ");
        try writeTimestamp(buf, gpa, e.timestamp);
        try app(buf, gpa, " | ");
        try app(buf, gpa, e.direction.toWire());
        try app(buf, gpa, " | ");
        try app(buf, gpa, e.message_type.toWire());
        try app(buf, gpa, " | ");
        try mdEscaped(buf, gpa, e.action orelse "-");
        try app(buf, gpa, " | ");
        try mdEscaped(buf, gpa, e.message_id);
        try app(buf, gpa, " |\n");
    }
    try mdTruncationNote(buf, gpa, result.events.len, shown, "events");
}

fn mdTruncationNote(buf: *Buf, gpa: Allocator, total: usize, shown: usize, noun: []const u8) !void {
    if (total > shown) {
        try appf(buf, gpa, "\n_… and {d} more {s} (truncated)._\n", .{ total - shown, noun });
    }
}

// ---------------------------------------------------------------------------
// HTML report
// ---------------------------------------------------------------------------

/// Generate a self-contained HTML report (inline CSS, no external assets).
/// Caller owns the returned slice. All trace-derived content is HTML-escaped.
pub fn generateHtmlReport(gpa: Allocator, result: AnalysisResult) ![]u8 {
    var buf: Buf = .empty;
    errdefer buf.deinit(gpa);

    try app(&buf, gpa, "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n");
    try app(&buf, gpa, "  <meta charset=\"utf-8\">\n");
    try app(&buf, gpa, "  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n");
    try app(&buf, gpa, "  <title>OCPP DebugKit — Trace Analysis Report</title>\n");
    try app(&buf, gpa, "  <style>");
    try app(&buf, gpa, css_theme);
    try app(&buf, gpa, "</style>\n</head>\n<body>\n  <div class=\"container\">\n");

    try htmlHeader(&buf, gpa, result);
    try htmlSessionOverview(&buf, gpa, result);
    try htmlTimelineSummary(&buf, gpa, result);
    try htmlFailures(&buf, gpa, result);
    try htmlSuggestedSteps(&buf, gpa, result);
    try htmlEventAppendix(&buf, gpa, result);

    try app(&buf, gpa, "    <footer>Generated by OCPP DebugKit</footer>\n  </div>\n</body>\n</html>\n");

    return buf.toOwnedSlice(gpa);
}

fn htmlHeader(buf: *Buf, gpa: Allocator, result: AnalysisResult) !void {
    try app(buf, gpa, "<h1>OCPP DebugKit — Trace Analysis Report</h1>\n");

    if (result.metadata) |m| {
        var rows: Buf = .empty;
        defer rows.deinit(gpa);
        if (m.station_id) |x| try htmlMetaRow(&rows, gpa, "Station", x);
        if (m.ocpp_version) |x| try htmlMetaRow(&rows, gpa, "OCPP Version", x);
        if (m.source) |x| try htmlMetaRow(&rows, gpa, "Source", x);
        if (m.description) |x| try htmlMetaRow(&rows, gpa, "Description", x);
        if (rows.items.len > 0) {
            try app(buf, gpa, "<dl class=\"header-meta\">");
            try app(buf, gpa, rows.items);
            try app(buf, gpa, "</dl>\n");
        }
    }

    try app(buf, gpa, "<div class=\"stats\">");
    try htmlStat(buf, gpa, "Events", result.events.len);
    try htmlStat(buf, gpa, "Sessions", result.sessions.len);
    try htmlStat(buf, gpa, "Failures", result.failures.len);
    try htmlStat(buf, gpa, "Warnings", result.warnings.len);
    try app(buf, gpa, "</div>\n");

    if (result.warnings.len > 0) {
        try app(buf, gpa, "<h2>Parse Warnings</h2><ul>");
        for (result.warnings) |w| {
            try app(buf, gpa, "<li>");
            try htmlEscaped(buf, gpa, w.message);
            try app(buf, gpa, "</li>");
        }
        try app(buf, gpa, "</ul>\n");
    }
}

fn htmlMetaRow(buf: *Buf, gpa: Allocator, label: []const u8, value: []const u8) !void {
    try appf(buf, gpa, "<dt>{s}</dt><dd>", .{label});
    try htmlEscaped(buf, gpa, value);
    try app(buf, gpa, "</dd>");
}

fn htmlStat(buf: *Buf, gpa: Allocator, label: []const u8, value: usize) !void {
    try appf(buf, gpa, "<div class=\"stat\"><div class=\"stat-value\">{d}</div><div class=\"stat-label\">{s}</div></div>", .{ value, label });
}

fn htmlSessionOverview(buf: *Buf, gpa: Allocator, result: AnalysisResult) !void {
    if (result.sessions.len == 0) {
        try app(buf, gpa, "<h2>Session Overview</h2><p>No sessions detected.</p>\n");
        return;
    }

    try app(buf, gpa, "<h2>Session Overview</h2>\n<table>\n");
    try app(buf, gpa, "  <thead><tr><th>Session</th><th>Station</th><th>Connector</th><th>Transaction</th><th>Start</th><th>End</th><th>Duration</th><th>Status</th></tr></thead>\n  <tbody>\n");

    const shown = @min(result.sessions.len, max_listed_sessions);
    for (result.sessions[0..shown]) |session| {
        try app(buf, gpa, "<tr><td>");
        try htmlEscaped(buf, gpa, session.session_id);
        try app(buf, gpa, "</td><td>");
        try htmlEscaped(buf, gpa, session.station_id);
        try app(buf, gpa, "</td><td>");
        try htmlOptInt(buf, gpa, session.connector_id);
        try app(buf, gpa, "</td><td>");
        try htmlOptInt(buf, gpa, session.transaction_id);
        try app(buf, gpa, "</td><td>");
        try writeTimestamp(buf, gpa, session.start_time);
        try app(buf, gpa, "</td><td>");
        try writeTimestamp(buf, gpa, session.end_time);
        try app(buf, gpa, "</td><td>");
        try writeDuration(buf, gpa, sessionDuration(session));
        try app(buf, gpa, "</td><td>");
        try app(buf, gpa, session.status.toWire());
        try app(buf, gpa, "</td></tr>\n");
    }
    try app(buf, gpa, "  </tbody>\n</table>\n");
    try htmlTruncationNote(buf, gpa, result.sessions.len, shown, "sessions");
}

fn htmlOptInt(buf: *Buf, gpa: Allocator, v: ?i64) !void {
    if (v) |n| try appf(buf, gpa, "{d}", .{n}) else try app(buf, gpa, "-");
}

fn htmlTimelineSummary(buf: *Buf, gpa: Allocator, result: AnalysisResult) !void {
    if (result.summaries.len == 0) {
        try app(buf, gpa, "<h2>Timeline Summary</h2><p>No sessions to summarize.</p>\n");
        return;
    }

    try app(buf, gpa, "<h2>Timeline Summary</h2>\n");
    const shown = @min(result.summaries.len, max_listed_sessions);
    for (result.summaries[0..shown]) |s| {
        try app(buf, gpa, "<h3>");
        try htmlEscaped(buf, gpa, s.session_id);
        try app(buf, gpa, "</h3>\n<ul>\n");
        try appf(buf, gpa, "  <li><strong>Events:</strong> {d}</li>\n", .{s.event_count});
        try app(buf, gpa, "  <li><strong>Duration:</strong> ");
        try writeDuration(buf, gpa, s.duration_ms);
        try app(buf, gpa, "</li>\n");
        try appf(buf, gpa, "  <li><strong>Failures:</strong> {d}</li>\n", .{s.failure_count});
        try app(buf, gpa, "  <li><strong>Action Sequence:</strong> ");
        try htmlActionSequence(buf, gpa, s.action_sequence);
        try app(buf, gpa, "</li>\n</ul>\n");
    }
    try htmlTruncationNote(buf, gpa, result.summaries.len, shown, "sessions");
}

fn htmlActionSequence(buf: *Buf, gpa: Allocator, actions: []const []const u8) !void {
    if (actions.len == 0) {
        try app(buf, gpa, "None");
        return;
    }
    for (actions, 0..) |a, i| {
        if (i > 0) try app(buf, gpa, " → ");
        try htmlEscaped(buf, gpa, a);
    }
}

fn htmlFailures(buf: *Buf, gpa: Allocator, result: AnalysisResult) !void {
    if (result.failures.len == 0) {
        try app(buf, gpa, "<h2>Failures</h2><p class=\"ok-message\">No failures detected. ✅</p>\n");
        return;
    }

    try app(buf, gpa, "<h2>Failures</h2>\n");
    const shown = @min(result.failures.len, max_listed_failures);
    for (result.failures[0..shown]) |f| {
        try app(buf, gpa, "<div class=\"failure\">\n  <h3>");
        try appf(buf, gpa, "{s} ", .{severityEmoji(f.severity)});
        try htmlEscaped(buf, gpa, f.code.toWire());
        try app(buf, gpa, "</h3>\n  <p><span class=\"severity-badge ");
        try app(buf, gpa, severityClass(f.severity));
        try app(buf, gpa, "\">");
        try app(buf, gpa, f.severity.toWire());
        try app(buf, gpa, "</span></p>\n  <p><strong>Description:</strong> ");
        try htmlEscaped(buf, gpa, f.description);
        try app(buf, gpa, "</p>\n  <p><strong>Events:</strong> ");
        for (f.event_ids, 0..) |id, i| {
            if (i > 0) try app(buf, gpa, ", ");
            try app(buf, gpa, "<span class=\"event-id\">");
            try htmlEscaped(buf, gpa, id);
            try app(buf, gpa, "</span>");
        }
        try app(buf, gpa, "</p>\n  <p><strong>Suggested Steps:</strong></p>\n  <ol>\n");
        for (f.suggested_steps) |step| {
            try app(buf, gpa, "<li>");
            try htmlEscaped(buf, gpa, step);
            try app(buf, gpa, "</li>\n");
        }
        try app(buf, gpa, "  </ol>\n</div>\n");
    }
    try htmlTruncationNote(buf, gpa, result.failures.len, shown, "failures");
}

fn htmlSuggestedSteps(buf: *Buf, gpa: Allocator, result: AnalysisResult) !void {
    if (result.failures.len == 0) {
        try app(buf, gpa, "<h2>Suggested Next Steps</h2><p class=\"ok-message\">No issues detected. The trace appears to represent a normal charging session.</p>\n");
        return;
    }

    try app(buf, gpa, "<h2>Suggested Next Steps</h2>\n<ol>\n");
    var seen = std.StringHashMap(void).init(gpa);
    defer seen.deinit();
    for (result.failures) |f| {
        for (f.suggested_steps) |step| {
            const gop = try seen.getOrPut(step);
            if (gop.found_existing) continue;
            try app(buf, gpa, "<li>");
            try htmlEscaped(buf, gpa, step);
            try app(buf, gpa, "</li>\n");
        }
    }
    try app(buf, gpa, "</ol>\n");
}

fn htmlEventAppendix(buf: *Buf, gpa: Allocator, result: AnalysisResult) !void {
    if (result.events.len == 0) {
        try app(buf, gpa, "<h2>Event Appendix</h2><p>No events to display.</p>\n");
        return;
    }

    try app(buf, gpa, "<h2>Event Appendix</h2>\n<table>\n");
    try app(buf, gpa, "  <thead><tr><th>ID</th><th>Timestamp</th><th>Direction</th><th>Type</th><th>Action</th><th>MessageId</th></tr></thead>\n  <tbody>\n");

    const shown = @min(result.events.len, max_appendix_rows);
    for (result.events[0..shown]) |e| {
        try app(buf, gpa, "<tr><td>");
        try htmlEscaped(buf, gpa, e.id);
        try app(buf, gpa, "</td><td>");
        try writeTimestamp(buf, gpa, e.timestamp);
        try app(buf, gpa, "</td><td>");
        try app(buf, gpa, e.direction.toWire());
        try app(buf, gpa, "</td><td>");
        try app(buf, gpa, e.message_type.toWire());
        try app(buf, gpa, "</td><td>");
        try htmlEscaped(buf, gpa, e.action orelse "-");
        try app(buf, gpa, "</td><td><code>");
        try htmlEscaped(buf, gpa, e.message_id);
        try app(buf, gpa, "</code></td></tr>\n");
    }
    try app(buf, gpa, "  </tbody>\n</table>\n");
    try htmlTruncationNote(buf, gpa, result.events.len, shown, "events");
}

fn htmlTruncationNote(buf: *Buf, gpa: Allocator, total: usize, shown: usize, noun: []const u8) !void {
    if (total > shown) {
        try appf(buf, gpa, "<p><em>… and {d} more {s} (truncated).</em></p>\n", .{ total - shown, noun });
    }
}

/// Dark theme, ported verbatim from the toolkit's `reporter/html.ts` so the two
/// implementations render alike. Self-contained — no external fonts or assets.
const css_theme =
    \\
    \\  :root { color-scheme: dark; }
    \\  body {
    \\    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif;
    \\    background: #0d1117; color: #c9d1d9; margin: 0; padding: 2rem 1rem; line-height: 1.6;
    \\  }
    \\  .container { max-width: 960px; margin: 0 auto; }
    \\  h1 { color: #f0f6fc; border-bottom: 1px solid #30363d; padding-bottom: 0.5rem; }
    \\  h2 { color: #58a6ff; margin-top: 2.5rem; border-bottom: 1px solid #21262d; padding-bottom: 0.3rem; }
    \\  h3 { color: #d2a8ff; margin-top: 1.5rem; }
    \\  table { border-collapse: collapse; width: 100%; margin: 1rem 0; font-size: 0.875rem; }
    \\  th, td { border: 1px solid #30363d; padding: 0.5rem 0.75rem; text-align: left; }
    \\  th { background: #161b22; color: #f0f6fc; }
    \\  tr:nth-child(even) { background: #161b22; }
    \\  code { background: #161b22; padding: 0.15rem 0.4rem; border-radius: 4px; font-size: 0.85em; }
    \\  .header-meta { display: grid; grid-template-columns: max-content 1fr; gap: 0.25rem 1rem; margin: 1rem 0; }
    \\  .header-meta dt { color: #8b949e; font-weight: 600; }
    \\  .stats { display: flex; gap: 1.5rem; flex-wrap: wrap; margin: 1rem 0; }
    \\  .stat { background: #161b22; border: 1px solid #30363d; border-radius: 6px; padding: 0.75rem 1.25rem; text-align: center; }
    \\  .stat .stat-value { font-size: 1.5rem; font-weight: 700; color: #f0f6fc; }
    \\  .stat .stat-label { color: #8b949e; font-size: 0.8rem; text-transform: uppercase; letter-spacing: 0.05em; }
    \\  .failure { background: #161b22; border: 1px solid #30363d; border-radius: 6px; padding: 1rem 1.25rem; margin: 1rem 0; }
    \\  .severity-badge { display: inline-block; padding: 0.15rem 0.5rem; border-radius: 12px; font-size: 0.75rem; font-weight: 600; text-transform: uppercase; }
    \\  .severity-critical { background: #da3633; color: #fff; }
    \\  .severity-warning { background: #d29922; color: #1a1a1a; }
    \\  .severity-info { background: #1f6feb; color: #fff; }
    \\  .severity-default { background: #30363d; color: #c9d1d9; }
    \\  .ok-message { color: #3fb950; font-style: italic; }
    \\  ol, ul { padding-left: 1.5rem; }
    \\  .event-id { color: #8b949e; font-family: monospace; }
    \\  footer { color: #8b949e; font-size: 0.8rem; margin-top: 3rem; padding-top: 1rem; border-top: 1px solid #21262d; }
    \\
;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const parser = @import("parser.zig");
const timeline = @import("timeline.zig");
const detection = @import("detection.zig");
const summarizer = @import("summarizer.zig");

/// Run the full engine pipeline over a trace and assemble an `AnalysisResult`.
fn analyze(a: Allocator, trace_json: []const u8, metadata: ?types.TraceMetadata) !AnalysisResult {
    const parsed = try parser.parseTrace(a, trace_json);
    const sessions = try timeline.buildSessionTimeline(a, parsed.events);
    const failures = try detection.detectFailures(a, parsed.events, sessions);
    const summaries = try summarizer.summarizeSessions(a, sessions, failures);
    return .{
        .events = parsed.events,
        .sessions = sessions,
        .failures = failures,
        .summaries = summaries,
        .warnings = parsed.warnings,
        .metadata = metadata,
    };
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "markdown report over the clean fixture has all sections and a healthy state" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const trace = @embedFile("conformance/fixtures/normal-session.json");
    const result = try analyze(a, trace, .{ .station_id = "STATION-CLEAN" });
    const md = try generateMarkdownReport(a, result);

    try testing.expect(contains(md, "# OCPP DebugKit — Trace Analysis Report"));
    try testing.expect(contains(md, "**Station:** STATION-CLEAN"));
    try testing.expect(contains(md, "## Session Overview"));
    try testing.expect(contains(md, "## Timeline Summary"));
    try testing.expect(contains(md, "## Failures"));
    try testing.expect(contains(md, "No failures detected. ✅"));
    try testing.expect(contains(md, "## Suggested Next Steps"));
    try testing.expect(contains(md, "## Event Appendix"));
    // Normalized ISO-8601 timestamps appear in the appendix (…Z cell).
    try testing.expect(contains(md, "Z |"));
}

test "writeTimestamp renders epoch milliseconds as ISO 8601 UTC" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cases = [_]struct { ms: i64, iso: []const u8 }{
        .{ .ms = 0, .iso = "1970-01-01T00:00:00.000Z" },
        .{ .ms = 1_609_459_200_000, .iso = "2021-01-01T00:00:00.000Z" },
        .{ .ms = 1_609_489_845_123, .iso = "2021-01-01T08:30:45.123Z" },
    };
    for (cases) |c| {
        var buf: Buf = .empty;
        defer buf.deinit(a);
        try writeTimestamp(&buf, a, c.ms);
        try testing.expectEqualStrings(c.iso, buf.items);
    }

    var nb: Buf = .empty;
    defer nb.deinit(a);
    try writeTimestamp(&nb, a, null);
    try testing.expectEqualStrings("Unknown", nb.items);
}

test "markdown report over failed-auth surfaces the failure and its steps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const trace = @embedFile("conformance/fixtures/failed-auth.json");
    const result = try analyze(a, trace, null);
    const md = try generateMarkdownReport(a, result);

    try testing.expect(contains(md, "FAILED_AUTHORIZATION"));
    try testing.expect(contains(md, "**Severity:** warning"));
    try testing.expect(contains(md, "**Suggested Steps:**"));
    // The failure count in the header reflects a non-empty detection.
    try testing.expect(!contains(md, "No failures detected."));
}

test "html report is a self-contained document with escaped, badged failures" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const trace = @embedFile("conformance/fixtures/failed-auth.json");
    const result = try analyze(a, trace, null);
    const html = try generateHtmlReport(a, result);

    try testing.expect(std.mem.startsWith(u8, html, "<!DOCTYPE html>"));
    try testing.expect(contains(html, "<title>OCPP DebugKit — Trace Analysis Report</title>"));
    try testing.expect(contains(html, "<style>")); // inline, self-contained
    try testing.expect(contains(html, "severity-badge"));
    try testing.expect(contains(html, "FAILED_AUTHORIZATION"));
    try testing.expect(contains(html, "</html>"));
    // Self-contained: no external stylesheet / script / asset references.
    try testing.expect(!contains(html, "<link"));
    try testing.expect(!contains(html, "src="));
    try testing.expect(!contains(html, "@import"));
    try testing.expect(!contains(html, "<script"));
}

test "reports escape hostile trace content on both paths" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Action and UniqueId carry markup and a table-breaking pipe.
    const trace =
        \\{"events":[{"message":[2,"id|<x>","Boot<script>alert(1)</script>",{}]}]}
    ;
    const result = try analyze(a, trace, .{ .station_id = "S<b>&\"'|Z" });

    const html = try generateHtmlReport(a, result);
    // Raw markup must not survive into the HTML.
    try testing.expect(!contains(html, "<script>alert(1)"));
    try testing.expect(!contains(html, "<b>&"));
    try testing.expect(contains(html, "&lt;script&gt;"));
    try testing.expect(contains(html, "&amp;")); // the metadata ampersand

    const md = try generateMarkdownReport(a, result);
    // The pipe in the UniqueId is escaped so the appendix table can't break.
    try testing.expect(contains(md, "id\\|"));
    try testing.expect(!contains(md, "| id|<x> |"));
}

test "list sections are bounded for dataset-scale traces" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 2,000 synthetic events — beyond the 1,000-row appendix cap.
    const n = 2000;
    const events = try a.alloc(types.Event, n);
    for (events, 0..) |*e, i| {
        e.* = .{
            .id = try std.fmt.allocPrint(a, "evt-{d:0>4}", .{i + 1}),
            .message_id = "m",
            .timestamp = 1_705_312_200_000,
            .direction = .cs_to_csms,
            .message_type = .call,
            .action = "Heartbeat",
            .payload = .null,
            .error_code = null,
            .error_description = null,
            .raw_message = .null,
        };
    }

    const result = AnalysisResult{
        .events = events,
        .sessions = &.{},
        .failures = &.{},
        .summaries = &.{},
        .warnings = &.{},
        .metadata = null,
    };
    const md = try generateMarkdownReport(a, result);

    // The header still reports the true total.
    try testing.expect(contains(md, "**Events:** 2000"));
    // The appendix is truncated: the first row is present, a row past the cap is not.
    try testing.expect(contains(md, "| evt-0001 |"));
    try testing.expect(!contains(md, "| evt-1500 |"));
    try testing.expect(contains(md, "more events (truncated)"));
}

test "empty analysis renders quiet placeholders, not crashes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = AnalysisResult{
        .events = &.{},
        .sessions = &.{},
        .failures = &.{},
        .summaries = &.{},
        .warnings = &.{},
        .metadata = null,
    };

    const md = try generateMarkdownReport(a, result);
    try testing.expect(contains(md, "No sessions detected."));
    try testing.expect(contains(md, "No sessions to summarize."));
    try testing.expect(contains(md, "No failures detected. ✅"));
    try testing.expect(contains(md, "No events to display."));

    const html = try generateHtmlReport(a, result);
    try testing.expect(contains(html, "No sessions detected."));
    try testing.expect(contains(html, "No events to display."));
}
