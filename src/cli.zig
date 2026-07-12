//! Headless CLI — the Studio binary's second face.
//!
//! `maybeRun` inspects argv; when the first argument is a known subcommand it
//! runs to completion and returns an exit code, and `main` then exits WITHOUT
//! opening a window (it calls `maybeRun` before `runWithOptions`). Everything the
//! CLI computes flows through the same pure engine the GUI uses.
//!
//! Two layers:
//!   * **render core** — `render*` functions are pure (bytes in, owned bytes out)
//!     so they are unit-tested with fixtures and no I/O.
//!   * **I/O shell** — `maybeRun` + the `cmd*` handlers parse argv, read files via
//!     `init.io`, and write results to stdout.
//!
//! Output goes to stdout (redirect to save: `studio report t.json > out.md`); a
//! `-o <file>` flag is a deferred convenience (see docs/cli-parity.md).

const std = @import("std");
const ocpp = @import("ocpp/ocpp.zig");
const parser = ocpp.parser;
const timeline = ocpp.timeline;
const detection = ocpp.detection;
const summarizer = ocpp.summarizer;
const types = ocpp.types;
const report = ocpp.report;
const anonymize = ocpp.anonymize;
const diff = ocpp.diff;
const conformance = ocpp.conformance;
const proxy = @import("capture/capture.zig").proxy;
const net = std.Io.net;

const Allocator = std.mem.Allocator;

/// Largest CLI-opened trace file (matches the GUI's command-line cap).
const max_file_bytes: usize = 256 * 1024 * 1024;

const ReportFormat = enum { markdown, html };
const DiffFormat = enum { text, json };

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

/// If argv names a CLI subcommand, run it and return its exit code (0 = success).
/// Returns null when there is no subcommand — the caller should open the GUI.
pub fn maybeRun(init: std.process.Init) ?u8 {
    const gpa = std.heap.page_allocator;
    const args = init.minimal.args.toSlice(gpa) catch return null;
    defer gpa.free(args);
    if (args.len < 2) return null;

    const cmd = args[1];
    const rest = args[2..];

    if (eql(cmd, "inspect")) return cmdInspect(gpa, init, rest);
    if (eql(cmd, "report")) return cmdReport(gpa, init, rest);
    if (eql(cmd, "diff")) return cmdDiff(gpa, init, rest);
    if (eql(cmd, "anonymize")) return cmdAnonymize(gpa, init, rest);
    if (eql(cmd, "ci")) return cmdCi(gpa, init.io);
    if (eql(cmd, "scenario")) return cmdScenario(gpa, init.io, rest);
    if (eql(cmd, "capture")) return cmdCapture(gpa, init, rest);
    if (eql(cmd, "help") or eql(cmd, "--help") or eql(cmd, "-h")) {
        _ = emit(init.io, help_text);
        return 0;
    }
    // Anything else is (probably) a trace path — let `main` open the GUI.
    return null;
}

const help_text =
    \\OCPP DebugKit Studio — headless CLI
    \\
    \\Usage: studio <command> [args]
    \\  inspect <file>                 Parse and analyze a trace; print a summary.
    \\  report <file> [-f markdown|html]   Generate a report (stdout).
    \\  diff <a> <b> [--format text|json]  Compare two traces.
    \\  anonymize <file>               Strip sensitive fields (stdout).
    \\  ci                             Run the conformance scenarios; exit 0/1.
    \\  scenario list | run <name>     List or run a conformance scenario.
    \\  capture --listen H:P --upstream ws://H:P [--ndjson]
    \\                                 Live WS proxy: relay + record a CP<->CSMS session.
    \\
    \\With no command, a trace path opens the GUI: studio path/to/trace.json
    \\
;

// ---------------------------------------------------------------------------
// Render core (pure: bytes in, owned bytes out)
// ---------------------------------------------------------------------------

/// Full engine pipeline over trusted input → an `AnalysisResult`. Detection is
/// skipped past its cap (ADR-0007); the trace still parses and correlates.
fn buildAnalysis(a: Allocator, trace_bytes: []const u8) !report.AnalysisResult {
    const parsed = try parser.parseTraceTrusted(a, trace_bytes);
    const sessions = try timeline.buildSessionTimeline(a, parsed.events);
    const failures: []const types.Failure = if (parsed.events.len > detection.max_events_for_detection)
        &.{}
    else
        try detection.detectFailures(a, parsed.events, sessions);
    const summaries = try summarizer.summarizeSessions(a, sessions, failures);
    return .{
        .events = parsed.events,
        .sessions = sessions,
        .failures = failures,
        .summaries = summaries,
        .warnings = parsed.warnings,
        .metadata = null,
    };
}

pub fn renderInspect(a: Allocator, trace_bytes: []const u8) ![]u8 {
    const r = try buildAnalysis(a, trace_bytes);
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    try appf(&buf, a, "OCPP DebugKit — trace inspection\n\n", .{});
    try appf(&buf, a, "Events:   {d}\nSessions: {d}\nFailures: {d}\nWarnings: {d}\n", .{
        r.events.len, r.sessions.len, r.failures.len, r.warnings.len,
    });
    if (r.failures.len > 0) {
        try appf(&buf, a, "\nFailures:\n", .{});
        for (r.failures) |f| {
            try appf(&buf, a, "  [{s}] {s} - {s}\n", .{ f.severity.toWire(), f.code.toWire(), f.description });
        }
    }
    return buf.toOwnedSlice(a);
}

pub fn renderReport(a: Allocator, trace_bytes: []const u8, format: ReportFormat) ![]u8 {
    const r = try buildAnalysis(a, trace_bytes);
    return switch (format) {
        .markdown => report.generateMarkdownReport(a, r),
        .html => report.generateHtmlReport(a, r),
    };
}

pub fn renderAnonymize(a: Allocator, trace_bytes: []const u8) ![]u8 {
    return anonymize.anonymizeJsonText(a, trace_bytes);
}

pub fn renderDiff(a: Allocator, a_bytes: []const u8, b_bytes: []const u8, format: DiffFormat) ![]u8 {
    const pa = try parser.parseTraceTrusted(a, a_bytes);
    const pb = try parser.parseTraceTrusted(a, b_bytes);
    const d = try diff.diffTraces(a, pa, pb);
    return switch (format) {
        .text => renderDiffText(a, d),
        .json => renderDiffJson(a, d),
    };
}

fn renderDiffText(a: Allocator, d: diff.TraceDiff) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    try appf(&buf, a, "OCPP DebugKit - trace diff\n\n", .{});
    try appf(&buf, a, "Only in A: {d}\n", .{d.only_in_a.len});
    for (d.only_in_a) |e| try appf(&buf, a, "  - {s}\n", .{e.message_id});
    try appf(&buf, a, "Only in B: {d}\n", .{d.only_in_b.len});
    for (d.only_in_b) |e| try appf(&buf, a, "  + {s}\n", .{e.message_id});
    try appf(&buf, a, "Modified fields: {d}\n", .{d.modified.len});
    for (d.modified) |m| try appf(&buf, a, "  ~ {s} {s}: {s} -> {s}\n", .{ m.message_id, @tagName(m.field), m.value_a, m.value_b });
    try appf(&buf, a, "Failures only in A: {d}\n", .{d.failures_only_in_a.len});
    for (d.failures_only_in_a) |f| try appf(&buf, a, "  - {s}\n", .{f.code.toWire()});
    try appf(&buf, a, "Failures only in B: {d}\n", .{d.failures_only_in_b.len});
    for (d.failures_only_in_b) |f| try appf(&buf, a, "  + {s}\n", .{f.code.toWire()});
    if (d.summary_diff.differences.len > 0) {
        try appf(&buf, a, "Summary differences:\n", .{});
        for (d.summary_diff.differences) |s| try appf(&buf, a, "  {s}\n", .{s});
    }
    return buf.toOwnedSlice(a);
}

fn renderDiffJson(a: Allocator, d: diff.TraceDiff) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    try appf(&buf, a, "{{\"onlyInA\":", .{});
    try jsonMessageIds(&buf, a, d.only_in_a);
    try appf(&buf, a, ",\"onlyInB\":", .{});
    try jsonMessageIds(&buf, a, d.only_in_b);
    try appf(&buf, a, ",\"modified\":[", .{});
    for (d.modified, 0..) |m, i| {
        if (i > 0) try buf.append(a, ',');
        try appf(&buf, a, "{{\"messageId\":", .{});
        try jsonString(&buf, a, m.message_id);
        try appf(&buf, a, ",\"field\":", .{});
        try jsonString(&buf, a, @tagName(m.field));
        try appf(&buf, a, ",\"valueA\":", .{});
        try jsonString(&buf, a, m.value_a);
        try appf(&buf, a, ",\"valueB\":", .{});
        try jsonString(&buf, a, m.value_b);
        try buf.append(a, '}');
    }
    try appf(&buf, a, "],\"failuresOnlyInA\":", .{});
    try jsonFailureCodes(&buf, a, d.failures_only_in_a);
    try appf(&buf, a, ",\"failuresOnlyInB\":", .{});
    try jsonFailureCodes(&buf, a, d.failures_only_in_b);
    try appf(&buf, a, ",\"summaryDifferences\":[", .{});
    for (d.summary_diff.differences, 0..) |s, i| {
        if (i > 0) try buf.append(a, ',');
        try jsonString(&buf, a, s);
    }
    try appf(&buf, a, "]}}\n", .{});
    return buf.toOwnedSlice(a);
}

fn jsonMessageIds(buf: *std.ArrayList(u8), a: Allocator, events: []const types.Event) !void {
    try buf.append(a, '[');
    for (events, 0..) |e, i| {
        if (i > 0) try buf.append(a, ',');
        try jsonString(buf, a, e.message_id);
    }
    try buf.append(a, ']');
}

fn jsonFailureCodes(buf: *std.ArrayList(u8), a: Allocator, failures: []const types.Failure) !void {
    try buf.append(a, '[');
    for (failures, 0..) |f, i| {
        if (i > 0) try buf.append(a, ',');
        try jsonString(buf, a, f.code.toWire());
    }
    try buf.append(a, ']');
}

fn jsonString(buf: *std.ArrayList(u8), a: Allocator, s: []const u8) !void {
    try buf.append(a, '"');
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice(a, "\\\""),
        '\\' => try buf.appendSlice(a, "\\\\"),
        '\n' => try buf.appendSlice(a, "\\n"),
        '\r' => try buf.appendSlice(a, "\\r"),
        '\t' => try buf.appendSlice(a, "\\t"),
        else => if (c < 0x20) try appf(buf, a, "\\u{x:0>4}", .{c}) else try buf.append(a, c),
    };
    try buf.append(a, '"');
}

// ---------------------------------------------------------------------------
// Command handlers (I/O shell)
// ---------------------------------------------------------------------------

fn cmdInspect(gpa: Allocator, init: std.process.Init, args: []const []const u8) u8 {
    if (args.len != 1) return usageErr("inspect: expected exactly <file>");
    const bytes = readFile(init, gpa, args[0]) catch |e| return ioErr("inspect", args[0], e);
    defer gpa.free(bytes);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const out = renderInspect(arena.allocator(), bytes) catch |e| return renderErr("inspect", e);
    return emit(init.io, out);
}

fn cmdReport(gpa: Allocator, init: std.process.Init, args: []const []const u8) u8 {
    var file: ?[]const u8 = null;
    var format: ReportFormat = .markdown;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eql(arg, "-f") or eql(arg, "--format")) {
            i += 1;
            if (i >= args.len) return usageErr("report: -f needs a value");
            format = parseReportFormat(args[i]) orelse return usageErr("report: format must be 'markdown' or 'html'");
        } else if (file == null) {
            file = arg;
        } else return usageErr("report: unexpected extra argument");
    }
    const path = file orelse return usageErr("report: missing <file>");
    const bytes = readFile(init, gpa, path) catch |e| return ioErr("report", path, e);
    defer gpa.free(bytes);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const out = renderReport(arena.allocator(), bytes, format) catch |e| return renderErr("report", e);
    return emit(init.io, out);
}

fn cmdDiff(gpa: Allocator, init: std.process.Init, args: []const []const u8) u8 {
    var a_path: ?[]const u8 = null;
    var b_path: ?[]const u8 = null;
    var format: DiffFormat = .text;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eql(arg, "--format")) {
            i += 1;
            if (i >= args.len) return usageErr("diff: --format needs a value");
            format = parseDiffFormat(args[i]) orelse return usageErr("diff: format must be 'text' or 'json'");
        } else if (a_path == null) {
            a_path = arg;
        } else if (b_path == null) {
            b_path = arg;
        } else return usageErr("diff: unexpected extra argument");
    }
    const pa = a_path orelse return usageErr("diff: missing <a> <b>");
    const pb = b_path orelse return usageErr("diff: missing <b>");
    const a_bytes = readFile(init, gpa, pa) catch |e| return ioErr("diff", pa, e);
    defer gpa.free(a_bytes);
    const b_bytes = readFile(init, gpa, pb) catch |e| return ioErr("diff", pb, e);
    defer gpa.free(b_bytes);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const out = renderDiff(arena.allocator(), a_bytes, b_bytes, format) catch |e| return renderErr("diff", e);
    return emit(init.io, out);
}

fn cmdAnonymize(gpa: Allocator, init: std.process.Init, args: []const []const u8) u8 {
    if (args.len != 1) return usageErr("anonymize: expected exactly <file>");
    const bytes = readFile(init, gpa, args[0]) catch |e| return ioErr("anonymize", args[0], e);
    defer gpa.free(bytes);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const out = renderAnonymize(arena.allocator(), bytes) catch |e| return renderErr("anonymize", e);
    return emit(init.io, out);
}

fn cmdCi(gpa: Allocator, io: std.Io) u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var buf: [8192]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    const w = &fw.interface;
    const all_ok = conformance.runAll(arena.allocator(), w) catch |e| return renderErr("ci", e);
    w.flush() catch return 1;
    return if (all_ok) 0 else 1;
}

fn cmdScenario(gpa: Allocator, io: std.Io, args: []const []const u8) u8 {
    if (args.len < 1) return usageErr("scenario: expected 'list' or 'run <name>'");
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    const w = &fw.interface;

    if (eql(args[0], "list")) {
        for (conformance.scenarioNames()) |name| w.print("{s}\n", .{name}) catch return 1;
        w.flush() catch return 1;
        return 0;
    }
    if (eql(args[0], "run")) {
        if (args.len < 2) return usageErr("scenario run: missing <name>");
        const res = conformance.runNamed(arena.allocator(), w, args[1]) catch |e| return renderErr("scenario", e);
        w.flush() catch return 1;
        const ok = res orelse {
            std.debug.print("error: unknown scenario '{s}'\n", .{args[1]});
            return 2;
        };
        return if (ok) 0 else 1;
    }
    return usageErr("scenario: expected 'list' or 'run <name>'");
}

const CaptureOptions = struct {
    listen_host: []const u8,
    listen_port: u16,
    upstream_host: []const u8,
    upstream_port: u16,
    /// `host:port` used for the upstream `Host` header.
    upstream_authority: []const u8,
    ndjson: bool,
};

const CaptureArgError = error{ MissingListen, MissingUpstream, BadListen, BadUpstream, TlsUnsupported, Unexpected };

const HostPort = struct { host: []const u8, port: u16 };

/// Split `host:port` on the last colon. An empty host uses `default_host`; a
/// bare value with no `:port` uses `default_port` (null → a port is required).
fn splitHostPort(s: []const u8, default_host: []const u8, default_port: ?u16) ?HostPort {
    if (std.mem.lastIndexOfScalar(u8, s, ':')) |idx| {
        const host = if (idx == 0) default_host else s[0..idx];
        const port = std.fmt.parseInt(u16, s[idx + 1 ..], 10) catch return null;
        return .{ .host = host, .port = port };
    }
    if (default_port) |dp| return .{ .host = s, .port = dp };
    return null;
}

/// Parse a `ws://host:port/path` upstream: scheme and path are optional and the
/// path is ignored (the proxy mirrors the CP's request path). `wss://` is
/// rejected — TLS is post-0.5 (ADR-0008).
fn parseUpstream(s: []const u8) CaptureArgError!HostPort {
    var rest = s;
    if (std.mem.startsWith(u8, rest, "wss://")) return error.TlsUnsupported;
    if (std.mem.startsWith(u8, rest, "ws://")) rest = rest["ws://".len..];
    const authority = if (std.mem.indexOfScalar(u8, rest, '/')) |slash| rest[0..slash] else rest;
    return splitHostPort(authority, "127.0.0.1", 80) orelse error.BadUpstream;
}

/// Pure argument parser for `capture` — unit-tested, no I/O.
fn parseCaptureArgs(args: []const []const u8) CaptureArgError!CaptureOptions {
    var listen: ?[]const u8 = null;
    var upstream: ?[]const u8 = null;
    var ndjson = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eql(arg, "--listen")) {
            i += 1;
            if (i >= args.len) return error.BadListen;
            listen = args[i];
        } else if (eql(arg, "--upstream")) {
            i += 1;
            if (i >= args.len) return error.BadUpstream;
            upstream = args[i];
        } else if (eql(arg, "--ndjson")) {
            ndjson = true;
        } else return error.Unexpected;
    }
    const l = listen orelse return error.MissingListen;
    const u = upstream orelse return error.MissingUpstream;
    const la = splitHostPort(l, "127.0.0.1", null) orelse return error.BadListen;
    const authority = if (std.mem.startsWith(u8, u, "ws://")) u["ws://".len..] else u;
    const ua = try parseUpstream(u);
    return .{
        .listen_host = la.host,
        .listen_port = la.port,
        .upstream_host = ua.host,
        .upstream_port = ua.port,
        .upstream_authority = if (std.mem.indexOfScalar(u8, authority, '/')) |slash| authority[0..slash] else authority,
        .ndjson = ndjson,
    };
}

/// `capture` — a live WebSocket MITM proxy: relay a CP<->CSMS session, decode and
/// record it, and run detection. One session, then exit. With `--ndjson`, each
/// captured event streams to stdout as a JSONL line (redirect to save a trace —
/// `studio capture … --ndjson > session.jsonl`); otherwise a summary is printed.
fn cmdCapture(gpa: Allocator, init: std.process.Init, args: []const []const u8) u8 {
    const opts = parseCaptureArgs(args) catch |e| return usageErr(switch (e) {
        error.MissingListen => "capture: missing --listen <host:port>",
        error.MissingUpstream => "capture: missing --upstream ws://<host:port>",
        error.BadListen => "capture: invalid --listen (want host:port)",
        error.BadUpstream => "capture: invalid --upstream (want ws://host:port)",
        error.TlsUnsupported => "capture: wss:// (TLS) is not supported yet",
        error.Unexpected => "capture: unexpected argument",
    });

    const io = init.io;
    const listen_addr = net.IpAddress.parse(opts.listen_host, opts.listen_port) catch
        return usageErr("capture: --listen host must be an IP address");
    const upstream_addr = net.IpAddress.parse(opts.upstream_host, opts.upstream_port) catch
        return usageErr("capture: --upstream host must be an IP address");

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var stdout_buf: [64 * 1024]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &stdout_buf);
    const w = &fw.interface;

    var sink = proxy.Sink{ .gpa = a };
    defer sink.deinit();
    if (opts.ndjson) sink.record = w;

    proxy.run(io, a, listen_addr, upstream_addr, opts.upstream_authority, &sink, .{ .wall = io }) catch |e|
        return renderErr("capture", e);
    if (opts.ndjson) w.flush() catch return 1;

    // Session summary. With --ndjson stdout is the trace stream, so it goes to
    // stderr; otherwise to stdout.
    const failures: []const types.Failure = sink.detect(a) catch &.{};
    if (opts.ndjson) {
        std.debug.print("captured {d} events, {d} failures\n", .{ sink.count(), failures.len });
        return 0;
    }
    const summary = std.fmt.allocPrint(a, "Captured {d} events, {d} failures.\n", .{ sink.count(), failures.len }) catch return 1;
    return emit(io, summary);
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn parseReportFormat(s: []const u8) ?ReportFormat {
    if (eql(s, "markdown") or eql(s, "md")) return .markdown;
    if (eql(s, "html")) return .html;
    return null;
}

fn parseDiffFormat(s: []const u8) ?DiffFormat {
    if (eql(s, "text")) return .text;
    if (eql(s, "json")) return .json;
    return null;
}

fn readFile(init: std.process.Init, gpa: Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .limited(max_file_bytes));
}

/// Write `bytes` to stdout. Returns 0, or 1 on a write failure.
fn emit(io: std.Io, bytes: []const u8) u8 {
    std.Io.File.stdout().writeStreamingAll(io, bytes) catch return 1;
    return 0;
}

fn appf(buf: *std.ArrayList(u8), gpa: Allocator, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(gpa, fmt, args);
    defer gpa.free(s);
    try buf.appendSlice(gpa, s);
}

fn usageErr(msg: []const u8) u8 {
    std.debug.print("error: {s}\n", .{msg});
    return 2;
}

fn ioErr(cmd: []const u8, path: []const u8, e: anyerror) u8 {
    std.debug.print("error: {s}: cannot read {s}: {s}\n", .{ cmd, path, @errorName(e) });
    return 1;
}

fn renderErr(cmd: []const u8, e: anyerror) u8 {
    std.debug.print("error: {s}: {s}\n", .{ cmd, @errorName(e) });
    return 1;
}

// ---------------------------------------------------------------------------
// Tests (render core + scenario runner)
// ---------------------------------------------------------------------------

const testing = std.testing;
const sample = @embedFile("ocpp/testdata/normal-session.json");
const failed_auth = @embedFile("ocpp/conformance/fixtures/failed-auth.json");
const normal_fixture = @embedFile("ocpp/conformance/fixtures/normal-session.json");

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "renderInspect summarizes counts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try renderInspect(arena.allocator(), sample);
    try testing.expect(contains(out, "OCPP DebugKit — trace inspection"));
    try testing.expect(contains(out, "Events:   22"));
    try testing.expect(contains(out, "Sessions: 1"));
}

test "renderReport emits Markdown and HTML" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const md = try renderReport(a, sample, .markdown);
    try testing.expect(contains(md, "# OCPP DebugKit — Trace Analysis Report"));
    const html = try renderReport(a, sample, .html);
    try testing.expect(std.mem.startsWith(u8, html, "<!DOCTYPE html>"));
}

test "renderAnonymize replaces sensitive fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try renderAnonymize(arena.allocator(),
        \\{"events":[{"message":[2,"m1","Authorize",{"idTag":"SECRET"}]}]}
    );
    try testing.expect(contains(out, "\"idTag\": \"anonymized\""));
    try testing.expect(!contains(out, "SECRET"));
}

test "renderDiff produces text and JSON over failed-auth vs normal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try renderDiff(a, failed_auth, normal_fixture, .text);
    try testing.expect(contains(text, "trace diff"));
    try testing.expect(contains(text, "FAILED_AUTHORIZATION")); // detected only in A
    try testing.expect(contains(text, "Failures only in B: 0")); // the clean trace has none

    const json = try renderDiff(a, failed_auth, normal_fixture, .json);
    try testing.expect(contains(json, "FAILED_AUTHORIZATION"));
    try testing.expect(contains(json, "\"failuresOnlyInB\":[]"));
    // Valid JSON that re-parses.
    _ = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
}

test "the scenario runner passes every locked golden" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var out: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&out);
    const all_ok = try conformance.runAll(arena.allocator(), &w);
    try testing.expect(all_ok);
    try testing.expect(contains(w.buffered(), "PASS normal-session"));
}

test "runNamed distinguishes a known scenario from an unknown one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&out);
    try testing.expectEqual(@as(?bool, true), try conformance.runNamed(a, &w, "failed-auth"));
    var out2: [1024]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&out2);
    try testing.expectEqual(@as(?bool, null), try conformance.runNamed(a, &w2, "does-not-exist"));
}

test "parseCaptureArgs parses listen, upstream, and ndjson" {
    const args = [_][]const u8{ "--listen", "127.0.0.1:8080", "--upstream", "ws://10.0.0.5:9000/ocpp", "--ndjson" };
    const opts = try parseCaptureArgs(&args);
    try testing.expectEqualStrings("127.0.0.1", opts.listen_host);
    try testing.expectEqual(@as(u16, 8080), opts.listen_port);
    try testing.expectEqualStrings("10.0.0.5", opts.upstream_host);
    try testing.expectEqual(@as(u16, 9000), opts.upstream_port);
    try testing.expectEqualStrings("10.0.0.5:9000", opts.upstream_authority);
    try testing.expect(opts.ndjson);
}

test "parseCaptureArgs: defaults, missing args, and rejections" {
    // Empty host defaults to loopback; upstream without a port defaults to 80.
    const ok = [_][]const u8{ "--listen", ":8080", "--upstream", "ws://10.0.0.5" };
    const opts = try parseCaptureArgs(&ok);
    try testing.expectEqualStrings("127.0.0.1", opts.listen_host);
    try testing.expectEqual(@as(u16, 80), opts.upstream_port);
    try testing.expect(!opts.ndjson);

    const missing_up = [_][]const u8{ "--listen", "127.0.0.1:8080" };
    try testing.expectError(error.MissingUpstream, parseCaptureArgs(&missing_up));
    const missing_listen = [_][]const u8{ "--upstream", "ws://x:1" };
    try testing.expectError(error.MissingListen, parseCaptureArgs(&missing_listen));
    const no_port = [_][]const u8{ "--listen", "127.0.0.1", "--upstream", "ws://10.0.0.5:9000" };
    try testing.expectError(error.BadListen, parseCaptureArgs(&no_port));
    const tls = [_][]const u8{ "--listen", "127.0.0.1:8080", "--upstream", "wss://secure:443" };
    try testing.expectError(error.TlsUnsupported, parseCaptureArgs(&tls));
    const bogus = [_][]const u8{"--frobnicate"};
    try testing.expectError(error.Unexpected, parseCaptureArgs(&bogus));
}
