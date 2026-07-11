//! Live-capture MITM proxy — the pump pipeline.
//!
//! Studio sits between a charge point and its CSMS: `cp <-> studio <-> csms`.
//! For each direction it **relays every WebSocket frame verbatim** (Studio is
//! transparent) while **tapping a copy** to decode into canonical events, record
//! to the trace format, and run detection over.
//!
//! Verbatim relay is correct because the masking polarity is preserved hop for
//! hop: CP→CSMS frames are client→server (masked) on both hops, CSMS→CP frames
//! are server→client (unmasked) on both hops — so the raw bytes can be forwarded
//! untouched. The tap decodes a *copy* (decode unmasks in place), never the
//! bytes being relayed.
//!
//! This file is the socket-free **pipeline**: `pumpDirection` drives one
//! direction over a generic `Io.Reader`/`Io.Writer`, so the whole thing is
//! unit-testable in memory. The real-socket accept/dial/connect wiring and the
//! `io.async` bidirectional concurrency build on top of this (closing #56).
//!
//! Hardening: frames are bounded (`max_frame_bytes`); a per-session event cap
//! bounds retained memory; a frame that fails to decode is dropped, not fatal.

const std = @import("std");
const ocpp = @import("../ocpp/ocpp.zig");
const ws = @import("ws.zig");
const decode = @import("decode.zig");

const types = ocpp.types;
const detection = ocpp.detection;
const timeline = ocpp.timeline;

const Direction = types.Direction;
const Event = types.Event;

/// Largest single relayed frame. A frame past this closes the session — a
/// hostile peer can't force an unbounded buffer. Generous for OCPP-J, which is
/// small JSON.
pub const max_frame_bytes: usize = 1 * 1024 * 1024; // 1 MiB

/// Default per-session cap on retained decoded events.
pub const default_max_events: usize = 1_000_000;

/// Wall-clock receipt time in epoch milliseconds — the default `now` for a live
/// session. Always ≥ 10^12, so recordings survive the offline normalizer's
/// seconds/ms threshold unchanged (see `decode`).
pub fn wallClockMs() ?i64 {
    return std.time.milliTimestamp();
}

// --------------------------------------------------------------------- sink

/// The destination for tapped events. Both pump directions feed one `Sink`.
/// Retained events are allocated from `gpa` — pass a per-session arena so the
/// whole capture frees at once. The pipeline here is single-writer; the
/// concurrent socket path (#56, part 2) guards ingest with a `std.Io.Mutex`.
pub const Sink = struct {
    gpa: std.mem.Allocator,
    events: std.ArrayList(Event) = .empty,
    seq: usize = 0,
    /// Frames that arrived but could not be decoded (malformed JSON / non-OCPP).
    dropped: usize = 0,
    /// Optional JSONL recorder. Each ingested message appends one line.
    record: ?*std.Io.Writer = null,
    max_events: usize = default_max_events,

    pub fn deinit(self: *Sink) void {
        self.events.deinit(self.gpa);
    }

    /// Ingest one complete OCPP-J message `text` arriving from `origin` at
    /// `received_ms`. Decodes it to a canonical event and, if a recorder is set,
    /// appends a JSONL record line embedding the original message bytes. A
    /// message that fails to decode is counted in `dropped` and skipped — one
    /// bad frame never aborts the session.
    pub fn ingest(self: *Sink, text: []const u8, origin: Direction, received_ms: ?i64) !void {
        if (self.events.items.len >= self.max_events) return;

        const seq = self.seq + 1;
        const ev = decode.decodeEvent(self.gpa, text, origin, received_ms, seq) catch {
            self.dropped += 1;
            return;
        };
        self.seq = seq;
        try self.events.append(self.gpa, ev);
        if (self.record) |w| try writeRecord(w, received_ms, origin, text);
    }

    /// Run detection over everything captured so far. Streaming callers invoke
    /// this on a cadence to surface the current failure set; the session-end
    /// path calls it once. `arena` holds the transient sessions and the returned
    /// failures. Detection is O(n²) past `detection.max_events_for_detection`,
    /// so on very long sessions it re-runs within that cap until the O(n)
    /// rewrite (#36).
    pub fn detect(self: *Sink, arena: std.mem.Allocator) ![]types.Failure {
        const sessions = try timeline.buildSessionTimeline(arena, self.events.items);
        return detection.detectFailures(arena, self.events.items, sessions);
    }

    /// Number of events captured so far.
    pub fn count(self: *Sink) usize {
        return self.events.items.len;
    }
};

/// Append one JSONL trace record for `message_text`, the exact OCPP-J bytes off
/// the wire. Direction and timestamp are written explicitly so the recording
/// re-parses offline to the same events (portability; see `decode`).
fn writeRecord(w: *std.Io.Writer, received_ms: ?i64, origin: Direction, message_text: []const u8) !void {
    if (received_ms) |ts| {
        try w.print("{{\"timestamp\":{d},\"direction\":\"{s}\",\"message\":{s}}}\n", .{ ts, origin.toWire(), message_text });
    } else {
        try w.print("{{\"direction\":\"{s}\",\"message\":{s}}}\n", .{ origin.toWire(), message_text });
    }
}

// --------------------------------------------------------------------- pump

/// Read one whole WebSocket frame off `src` into `scratch`, returning the raw
/// frame bytes (a slice of `scratch`). Returns `null` at a clean frame boundary
/// when the peer has closed (or truncates mid-frame). Errors only on a frame
/// larger than `scratch`.
fn readFrameBytes(src: *std.Io.Reader, scratch: []u8) !?[]u8 {
    const first2 = src.peek(2) catch |err| switch (err) {
        error.EndOfStream => return null,
        else => |e| return e,
    };
    const b1 = first2[1];
    const lc = b1 & 0x7f;
    var need: usize = 2;
    if (lc == 126) need += 2 else if (lc == 127) need += 8;
    if ((b1 & 0x80) != 0) need += 4; // mask key

    const head = src.peek(need) catch |err| switch (err) {
        error.EndOfStream => return null,
        else => |e| return e,
    };
    var payload_len: usize = lc;
    if (lc == 126) {
        payload_len = std.mem.readInt(u16, head[2..][0..2], .big);
    } else if (lc == 127) {
        const p = std.mem.readInt(u64, head[2..][0..8], .big);
        if (p > max_frame_bytes) return error.FrameTooLarge;
        payload_len = @intCast(p);
    }

    const total = need + payload_len;
    if (total > scratch.len) return error.FrameTooLarge;
    const raw = src.peek(total) catch |err| switch (err) {
        error.EndOfStream => return null,
        else => |e| return e,
    };
    @memcpy(scratch[0..total], raw);
    try src.discardAll(total);
    return scratch[0..total];
}

/// Pump one direction: read frames from `src`, relay their raw bytes verbatim to
/// `dst`, and feed decoded **data** messages to `sink`. Control frames (ping /
/// pong / close) are relayed so the real peers handle them; a relayed close ends
/// the direction. Returns when the source closes.
///
/// `gpa` backs this direction's transient scratch + reassembly buffer (freed on
/// return); retained events go to `sink.gpa`. `now` supplies each message's
/// receipt time.
pub fn pumpDirection(
    gpa: std.mem.Allocator,
    src: *std.Io.Reader,
    dst: *std.Io.Writer,
    origin: Direction,
    sink: *Sink,
    now: *const fn () ?i64,
) !void {
    // Client→server frames are masked; server→client are not (RFC 6455 §5.1).
    const expect_masked = origin == .cs_to_csms;

    const scratch = try gpa.alloc(u8, max_frame_bytes);
    defer gpa.free(scratch);
    var assembler = ws.Assembler{};
    defer assembler.deinit(gpa);

    while (true) {
        const raw = (try readFrameBytes(src, scratch)) orelse break;

        // Relay verbatim BEFORE decoding (decode unmasks the copy in place).
        try dst.writeAll(raw);
        try dst.flush();

        const dec = (try ws.decodeFrame(raw, expect_masked)) orelse break;
        if (dec.frame.opcode.isControl()) {
            if (dec.frame.opcode == .close) break;
            continue; // ping / pong: relayed, nothing to tap
        }
        if (try assembler.push(gpa, dec.frame)) |msg| {
            try sink.ingest(msg.payload, origin, now());
        }
    }
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

fn testNow() ?i64 {
    return 1_705_312_800_000; // fixed epoch-ms ≥ 10^12
}

test "pump relays frames verbatim and taps decoded messages" {
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    // Two client→server (masked) OCPP-J Calls.
    const boot = "[2,\"m1\",\"BootNotification\",{\"chargePointVendor\":\"Acme\"}]";
    const hb = "[2,\"m2\",\"Heartbeat\",{}]";
    const f1 = try ws.encodeFrameAlloc(gpa, true, .text, boot, [4]u8{ 1, 2, 3, 4 });
    defer gpa.free(f1);
    const f2 = try ws.encodeFrameAlloc(gpa, true, .text, hb, [4]u8{ 5, 6, 7, 8 });
    defer gpa.free(f2);
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(gpa);
    try wire.appendSlice(gpa, f1);
    try wire.appendSlice(gpa, f2);

    var src = std.Io.Reader.fixed(wire.items);
    var relay_buf: [8192]u8 = undefined;
    var dst = std.Io.Writer.fixed(&relay_buf);
    var rec_buf: [8192]u8 = undefined;
    var rec = std.Io.Writer.fixed(&rec_buf);

    var sink = Sink{ .gpa = arena_state.allocator(), .record = &rec };
    defer sink.deinit();

    try pumpDirection(gpa, &src, &dst, .cs_to_csms, &sink, testNow);

    // Relay is byte-exact (still masked — Studio is transparent).
    try testing.expectEqualSlices(u8, wire.items, dst.buffered());

    // The tap captured both messages with the socket-known direction.
    try testing.expectEqual(@as(usize, 2), sink.events.items.len);
    try testing.expectEqualStrings("BootNotification", sink.events.items[0].action.?);
    try testing.expectEqual(Direction.cs_to_csms, sink.events.items[0].direction);
    try testing.expectEqualStrings("Heartbeat", sink.events.items[1].action.?);

    // The recording re-parses offline to the same events (portability).
    const reparsed = try ocpp.parser.parseTrace(arena_state.allocator(), rec.buffered());
    try testing.expectEqual(@as(usize, 2), reparsed.events.len);
    try testing.expectEqualStrings("BootNotification", reparsed.events[0].action.?);
    try testing.expectEqual(Direction.cs_to_csms, reparsed.events[0].direction);
    try testing.expectEqualStrings("m2", reparsed.events[1].message_id);
}

test "pump reassembles a fragmented message and stops on close" {
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    // A fragmented text message across three server→client (unmasked) frames,
    // then a close frame.
    const parts = [_]struct { fin: bool, op: ws.Opcode, p: []const u8 }{
        .{ .fin = false, .op = .text, .p = "[2,\"m1\"," },
        .{ .fin = false, .op = .continuation, .p = "\"Heartbeat\"," },
        .{ .fin = true, .op = .continuation, .p = "{}]" },
    };
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(gpa);
    for (parts) |fr| {
        const bytes = try ws.encodeFrameAlloc(gpa, fr.fin, fr.op, fr.p, null);
        defer gpa.free(bytes);
        try wire.appendSlice(gpa, bytes);
    }
    const closing = try ws.encodeFrameAlloc(gpa, true, .close, &[_]u8{ 0x03, 0xe8 }, null);
    defer gpa.free(closing);
    try wire.appendSlice(gpa, closing);
    // A frame after the close must not be tapped (pump stops at close).
    const after = try ws.encodeFrameAlloc(gpa, true, .text, "[2,\"m2\",\"Heartbeat\",{}]", null);
    defer gpa.free(after);
    try wire.appendSlice(gpa, after);

    var src = std.Io.Reader.fixed(wire.items);
    var relay_buf: [8192]u8 = undefined;
    var dst = std.Io.Writer.fixed(&relay_buf);
    var sink = Sink{ .gpa = arena_state.allocator() };
    defer sink.deinit();

    try pumpDirection(gpa, &src, &dst, .csms_to_cs, &sink, testNow);

    // Exactly one reassembled message; the post-close frame was not tapped.
    try testing.expectEqual(@as(usize, 1), sink.events.items.len);
    try testing.expectEqualStrings("m1", sink.events.items[0].message_id);
    try testing.expectEqualStrings("Heartbeat", sink.events.items[0].action.?);
    try testing.expectEqual(Direction.csms_to_cs, sink.events.items[0].direction);
}

test "sink detection matches an offline pass over the recording" {
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Two Authorizes rejected with idTagInfo.status "Invalid" — trips
    // FAILED_AUTHORIZATION, so the parity comparison is non-trivial.
    const msgs = [_][]const u8{
        "[2,\"m1\",\"Authorize\",{\"idTag\":\"BAD\"}]",
        "[3,\"m1\",{\"idTagInfo\":{\"status\":\"Invalid\"}}]",
        "[2,\"m2\",\"Authorize\",{\"idTag\":\"BAD\"}]",
        "[3,\"m2\",{\"idTagInfo\":{\"status\":\"Invalid\"}}]",
    };
    var rec_buf: [8192]u8 = undefined;
    var rec = std.Io.Writer.fixed(&rec_buf);
    var sink = Sink{ .gpa = arena, .record = &rec };
    defer sink.deinit();

    for (msgs, 0..) |m, i| {
        const origin: Direction = if (i % 2 == 0) .cs_to_csms else .csms_to_cs;
        try sink.ingest(m, origin, testNow());
    }

    // Streaming detection over the live events…
    const live_failures = try sink.detect(arena);
    // …equals a cold offline pass over the recorded trace.
    const reparsed = try ocpp.parser.parseTrace(arena, rec.buffered());
    const sessions = try timeline.buildSessionTimeline(arena, reparsed.events);
    const offline_failures = try detection.detectFailures(arena, reparsed.events, sessions);

    try testing.expectEqual(offline_failures.len, live_failures.len);
    try testing.expect(live_failures.len > 0);
    for (live_failures, offline_failures) |lf, off| {
        try testing.expectEqual(off.code, lf.code);
    }
}
