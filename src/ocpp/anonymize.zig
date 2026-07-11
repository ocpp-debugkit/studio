//! Trace anonymization — strip sensitive fields so a trace can be shared safely.
//!
//! Mirrors the toolkit's `cli/commands/anonymize.ts`: walk the parsed JSON,
//! rewrite known sensitive keys, resequence `transactionId`s, and redact PII
//! patterns (email / phone / IPv4) in string values, emitting pretty (2-space)
//! JSON. Pure and headless — the caller owns the allocator and any file I/O.
//!
//! Two faithfully-mirrored quirks of the toolkit code, flagged rather than
//! silently "fixed":
//!   * **Meter values are not transformed.** The toolkit docstring claims meter
//!     values are rescaled; the code does not touch them. We mirror the code.
//!     (A numeric meter value passes through unchanged; a *string* meter value of
//!     10–15 digits is caught by the phone pattern, exactly as in the toolkit.)
//!   * **`transactionId` resequences per occurrence.** Each `transactionId`
//!     number is replaced with the next counter value, so repeated occurrences of
//!     the same id get *different* numbers (correlation is not preserved). This
//!     matches the toolkit's `txCounter.next++`; a future enhancement could map
//!     distinct ids stably.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Buf = std.ArrayList(u8);

/// Explicit error set for the mutually-recursive emit functions (an inferred set
/// would form a dependency loop between `emitValue` and `emitEntryValue`).
const EmitError = Allocator.Error || error{MaxDepthExceeded};

/// Defensive bound on JSON nesting depth (input is untrusted). Trace payloads
/// nest only a few levels; std.json's parser also caps depth upstream.
const max_depth = 128;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Anonymize a parsed JSON value, returning pretty (2-space) JSON. Caller owns
/// the returned slice.
pub fn anonymizeToJson(gpa: Allocator, root: std.json.Value) ![]u8 {
    var buf: Buf = .empty;
    errdefer buf.deinit(gpa);
    var tx: usize = 1; // matches the toolkit's `txCounter = { next: 1 }`
    try emitValue(&buf, gpa, root, 0, &tx);
    try buf.append(gpa, '\n');
    return buf.toOwnedSlice(gpa);
}

/// Parse `json_text` and anonymize it. Convenience wrapper over
/// `anonymizeToJson`; the caller is responsible for size-limiting the input
/// (the CLI reads under the trusted-ingestion cap).
pub fn anonymizeJsonText(gpa: Allocator, json_text: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, json_text, .{});
    defer parsed.deinit();
    return anonymizeToJson(gpa, parsed.value);
}

// ---------------------------------------------------------------------------
// Emit helpers
// ---------------------------------------------------------------------------

fn app(buf: *Buf, gpa: Allocator, bytes: []const u8) !void {
    try buf.appendSlice(gpa, bytes);
}

fn appf(buf: *Buf, gpa: Allocator, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(gpa, fmt, args);
    defer gpa.free(s);
    try buf.appendSlice(gpa, s);
}

fn pad(buf: *Buf, gpa: Allocator, spaces: usize) !void {
    var i: usize = 0;
    while (i < spaces) : (i += 1) try buf.append(gpa, ' ');
}

/// Emit `s` as a JSON string literal (quoted + escaped), matching JSON.stringify.
fn emitJsonString(buf: *Buf, gpa: Allocator, s: []const u8) !void {
    try buf.append(gpa, '"');
    for (s) |c| switch (c) {
        '"' => try app(buf, gpa, "\\\""),
        '\\' => try app(buf, gpa, "\\\\"),
        '\n' => try app(buf, gpa, "\\n"),
        '\r' => try app(buf, gpa, "\\r"),
        '\t' => try app(buf, gpa, "\\t"),
        0x08 => try app(buf, gpa, "\\b"),
        0x0c => try app(buf, gpa, "\\f"),
        else => if (c < 0x20) try appf(buf, gpa, "\\u{x:0>4}", .{c}) else try buf.append(gpa, c),
    };
    try buf.append(gpa, '"');
}

fn isString(v: std.json.Value) bool {
    return switch (v) {
        .string => true,
        else => false,
    };
}

fn isNumber(v: std.json.Value) bool {
    return switch (v) {
        .integer, .float, .number_string => true,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Recursive emit + transform
// ---------------------------------------------------------------------------

fn emitValue(buf: *Buf, gpa: Allocator, v: std.json.Value, depth: usize, tx: *usize) EmitError!void {
    if (depth > max_depth) return error.MaxDepthExceeded;

    switch (v) {
        .null => try app(buf, gpa, "null"),
        .bool => |b| try app(buf, gpa, if (b) "true" else "false"),
        .integer => |n| try appf(buf, gpa, "{d}", .{n}),
        .float => |f| try appf(buf, gpa, "{d}", .{f}),
        .number_string => |s| try app(buf, gpa, s),
        .string => |s| {
            const redacted = try redact(gpa, s);
            defer gpa.free(redacted);
            try emitJsonString(buf, gpa, redacted);
        },
        .array => |arr| {
            if (arr.items.len == 0) {
                try app(buf, gpa, "[]");
                return;
            }
            try app(buf, gpa, "[\n");
            for (arr.items, 0..) |item, i| {
                try pad(buf, gpa, (depth + 1) * 2);
                try emitValue(buf, gpa, item, depth + 1, tx);
                if (i + 1 < arr.items.len) try buf.append(gpa, ',');
                try buf.append(gpa, '\n');
            }
            try pad(buf, gpa, depth * 2);
            try buf.append(gpa, ']');
        },
        .object => |obj| {
            const keys = obj.keys();
            const vals = obj.values();
            if (keys.len == 0) {
                try app(buf, gpa, "{}");
                return;
            }
            try app(buf, gpa, "{\n");
            for (keys, vals, 0..) |key, val, i| {
                try pad(buf, gpa, (depth + 1) * 2);
                try emitJsonString(buf, gpa, key);
                try app(buf, gpa, ": ");
                try emitEntryValue(buf, gpa, key, val, depth + 1, tx);
                if (i + 1 < keys.len) try buf.append(gpa, ',');
                try buf.append(gpa, '\n');
            }
            try pad(buf, gpa, depth * 2);
            try buf.append(gpa, '}');
        },
    }
}

/// Emit an object entry's value, applying the sensitive-key rules (mirrors the
/// toolkit's if/else chain in `anonymizeValue`). `child_depth` is the depth the
/// value's own nested containers render at.
fn emitEntryValue(buf: *Buf, gpa: Allocator, key: []const u8, val: std.json.Value, child_depth: usize, tx: *usize) EmitError!void {
    if (std.mem.eql(u8, key, "idTag") and isString(val)) return emitJsonString(buf, gpa, "anonymized");
    if (std.mem.eql(u8, key, "chargePointSerialNumber") or std.mem.eql(u8, key, "chargeBoxSerialNumber"))
        return emitJsonString(buf, gpa, "station-anon");
    if (std.mem.eql(u8, key, "stationId")) return emitJsonString(buf, gpa, "station-anon");
    if (std.mem.eql(u8, key, "transactionId") and isNumber(val)) {
        try appf(buf, gpa, "{d}", .{tx.*});
        tx.* += 1;
        return;
    }
    if (std.mem.eql(u8, key, "identifier") and isString(val)) return emitJsonString(buf, gpa, "anonymized");
    return emitValue(buf, gpa, val, child_depth, tx);
}

// ---------------------------------------------------------------------------
// PII redaction — three sequential passes (email → phone → IPv4), mirroring the
// toolkit's regex replacements. Zig std has no regex, so each pattern is a
// hand-rolled matcher scanned left-to-right with non-overlapping replacement.
// ---------------------------------------------------------------------------

fn redact(gpa: Allocator, s: []const u8) ![]u8 {
    const p1 = try replaceAll(gpa, s, matchEmailAt, "[redacted-email]");
    defer gpa.free(p1);
    const p2 = try replaceAll(gpa, p1, matchPhoneAt, "[redacted-phone]");
    defer gpa.free(p2);
    return replaceAll(gpa, p2, matchIpAt, "[redacted-ip]");
}

const MatchFn = *const fn (s: []const u8, i: usize) usize;

/// Replace every non-overlapping match (greedy, left-to-right) with `repl`,
/// mirroring JavaScript's global `String.replace`.
fn replaceAll(gpa: Allocator, s: []const u8, matchAt: MatchFn, repl: []const u8) ![]u8 {
    var out: Buf = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) {
        const len = matchAt(s, i);
        if (len > 0) {
            try out.appendSlice(gpa, repl);
            i += len;
        } else {
            try out.append(gpa, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// `[\w.+-]+@[\w-]+\.[\w.-]+`
fn matchEmailAt(s: []const u8, i: usize) usize {
    var j = i;
    // local part: [\w.+-]+
    const local_start = j;
    while (j < s.len and (isWord(s[j]) or s[j] == '.' or s[j] == '+' or s[j] == '-')) : (j += 1) {}
    if (j == local_start) return 0;
    // '@'
    if (j >= s.len or s[j] != '@') return 0;
    j += 1;
    // domain label 1: [\w-]+
    const d1_start = j;
    while (j < s.len and (isWord(s[j]) or s[j] == '-')) : (j += 1) {}
    if (j == d1_start) return 0;
    // '.'
    if (j >= s.len or s[j] != '.') return 0;
    j += 1;
    // domain rest: [\w.-]+
    const d2_start = j;
    while (j < s.len and (isWord(s[j]) or s[j] == '.' or s[j] == '-')) : (j += 1) {}
    if (j == d2_start) return 0;
    return j - i;
}

/// `\+?\d{10,15}[-\s]?\d{0,4}[-\s]?\d{0,4}`
fn matchPhoneAt(s: []const u8, i: usize) usize {
    var j = i;
    if (j < s.len and s[j] == '+') j += 1;
    // \d{10,15}
    const dig_start = j;
    while (j < s.len and std.ascii.isDigit(s[j]) and (j - dig_start) < 15) : (j += 1) {}
    if (j - dig_start < 10) return 0;
    // ([-\s]?\d{0,4}) twice
    j = consumeSepThenDigits(s, j, 4);
    j = consumeSepThenDigits(s, j, 4);
    return j - i;
}

fn consumeSepThenDigits(s: []const u8, start: usize, max_digits: usize) usize {
    var j = start;
    if (j < s.len and (s[j] == '-' or std.ascii.isWhitespace(s[j]))) j += 1;
    var n: usize = 0;
    while (j < s.len and std.ascii.isDigit(s[j]) and n < max_digits) : (j += 1) n += 1;
    return j;
}

/// `\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b`
fn matchIpAt(s: []const u8, i: usize) usize {
    // Leading word boundary: previous char is not a word char.
    if (i > 0 and isWord(s[i - 1])) return 0;
    var j = i;
    var group: usize = 0;
    while (group < 4) : (group += 1) {
        if (group > 0) {
            if (j >= s.len or s[j] != '.') return 0;
            j += 1;
        }
        const g_start = j;
        while (j < s.len and std.ascii.isDigit(s[j]) and (j - g_start) < 3) : (j += 1) {}
        if (j == g_start) return 0;
    }
    // Trailing word boundary: next char is not a word char.
    if (j < s.len and isWord(s[j])) return 0;
    return j - i;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn anonymizeText(a: Allocator, json: []const u8) ![]u8 {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
    return anonymizeToJson(a, v);
}

test "anonymize replaces known sensitive keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const out = try anonymizeText(a,
        \\{"idTag":"SECRET-TAG","chargePointSerialNumber":"SN-123","chargeBoxSerialNumber":"CB-9","stationId":"ST-42","identifier":"WHO","transactionId":500}
    );

    try testing.expect(contains(out, "\"idTag\": \"anonymized\""));
    try testing.expect(contains(out, "\"chargePointSerialNumber\": \"station-anon\""));
    try testing.expect(contains(out, "\"chargeBoxSerialNumber\": \"station-anon\""));
    try testing.expect(contains(out, "\"stationId\": \"station-anon\""));
    try testing.expect(contains(out, "\"identifier\": \"anonymized\""));
    try testing.expect(contains(out, "\"transactionId\": 1"));

    // Originals are gone.
    try testing.expect(!contains(out, "SECRET-TAG"));
    try testing.expect(!contains(out, "SN-123"));
    try testing.expect(!contains(out, "ST-42"));
    try testing.expect(!contains(out, "500"));
}

test "anonymize redacts email / phone / IPv4 in string values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const out = try anonymizeText(a,
        \\{"note":"mail bob@acme.io or call +12345678901, host 10.0.0.5 ok"}
    );

    try testing.expect(contains(out, "[redacted-email]"));
    try testing.expect(contains(out, "[redacted-phone]"));
    try testing.expect(contains(out, "[redacted-ip]"));
    try testing.expect(!contains(out, "bob@acme.io"));
    try testing.expect(!contains(out, "12345678901"));
    try testing.expect(!contains(out, "10.0.0.5"));
}

test "anonymize preserves numeric meter values (mirrors code, not docstring)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const out = try anonymizeText(a,
        \\{"meterStart":0,"meterStop":100,"sampledValue":[{"value":1234}]}
    );

    try testing.expect(contains(out, "\"meterStart\": 0"));
    try testing.expect(contains(out, "\"meterStop\": 100"));
    try testing.expect(contains(out, "\"value\": 1234"));
}

test "transactionId resequences per occurrence (deterministic, correlation not preserved)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const out = try anonymizeText(a,
        \\{"a":{"transactionId":900},"b":{"transactionId":900},"c":{"transactionId":42}}
    );

    try testing.expect(contains(out, "\"transactionId\": 1"));
    try testing.expect(contains(out, "\"transactionId\": 2"));
    try testing.expect(contains(out, "\"transactionId\": 3"));
    try testing.expect(!contains(out, "900"));
    try testing.expect(!contains(out, "42"));
}

test "anonymized output re-parses, recurses, and escapes strings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const out = try anonymizeText(a,
        \\{"events":[{"idTag":"X","payload":{"note":"has \"quotes\" and a\ttab"}},{"transactionId":7}]}
    );

    // Nested idTag was anonymized; nested transactionId resequenced.
    try testing.expect(contains(out, "\"idTag\": \"anonymized\""));
    try testing.expect(contains(out, "\"transactionId\": 1"));
    // Round-trips as valid JSON (escaping is correct): a parse error fails the test.
    _ = try std.json.parseFromSliceLeaky(std.json.Value, a, out, .{});
}

test "matchers: precise boundaries for phone and IPv4" {
    // 9 digits is too short for the phone pattern; 10 is the minimum.
    try testing.expectEqual(@as(usize, 0), matchPhoneAt("123456789", 0));
    try testing.expect(matchPhoneAt("1234567890", 0) >= 10);
    // IPv4: a clean dotted quad matches; a leading word char breaks the boundary.
    try testing.expectEqual(@as(usize, 7), matchIpAt("1.1.1.1", 0));
    try testing.expectEqual(@as(usize, 8), matchIpAt("10.0.0.5", 0));
    try testing.expectEqual(@as(usize, 0), matchIpAt("x1.2.3.4", 1));
    // A 4th octet with 4 digits breaks the trailing boundary.
    try testing.expectEqual(@as(usize, 0), matchIpAt("1.2.3.4567", 0));
}
