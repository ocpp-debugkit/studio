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

const net = std.Io.net;
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

/// Where a live session's receipt timestamps come from. Wall-clock time in Zig
/// 0.16 is read through `io`, so a plain function can't supply it — this small
/// source does, while staying deterministic under test.
pub const TimeSource = union(enum) {
    /// A fixed epoch-ms value — deterministic, for tests.
    fixed: i64,
    /// The real wall clock, read from `io` — live capture. Real wall-clock is
    /// always ≥ 10^12 ms, so recordings survive the offline normalizer's
    /// seconds/ms threshold unchanged (see `decode`).
    wall: std.Io,
    /// No clock; events are recorded without a timestamp.
    none,

    pub fn nowMs(self: TimeSource) ?i64 {
        return switch (self) {
            .fixed => |v| v,
            .none => null,
            .wall => |io| @intCast(@divTrunc(std.Io.Clock.now(.real, io).nanoseconds, 1_000_000)),
        };
    }
};

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
    /// Guards `ingest` when both pump directions feed this sink concurrently
    /// (the real-socket path). Null for the single-writer in-memory tests.
    /// `detect`/`count` are not guarded — call them when pumping is quiesced.
    mutex: ?*std.Io.Mutex = null,
    /// The `io` the guard cooperates with; set together with `mutex`.
    io: ?std.Io = null,

    pub fn deinit(self: *Sink) void {
        self.events.deinit(self.gpa);
    }

    /// Ingest one complete OCPP-J message `text` arriving from `origin` at
    /// `received_ms`. Decodes it to a canonical event and, if a recorder is set,
    /// appends a JSONL record line embedding the original message bytes. A
    /// message that fails to decode is counted in `dropped` and skipped — one
    /// bad frame never aborts the session.
    pub fn ingest(self: *Sink, text: []const u8, origin: Direction, received_ms: ?i64) !void {
        if (self.mutex) |m| m.lockUncancelable(self.io.?);
        defer if (self.mutex) |m| m.unlock(self.io.?);
        if (self.events.items.len >= self.max_events) return;

        const seq = self.seq + 1;
        const ev = decode.decodeEvent(self.gpa, text, origin, received_ms, seq) catch {
            self.dropped += 1;
            return;
        };
        self.seq = seq;
        try self.events.append(self.gpa, ev);
        if (self.record) |w| {
            try writeRecord(w, received_ms, origin, text);
            // Flush each record so `--ndjson` streams live (a no-op for the
            // fixed-buffer writers used in tests).
            w.flush() catch {};
        }
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
    time: TimeSource,
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
            try sink.ingest(msg.payload, origin, time.nowMs());
        }
    }
}

// ------------------------------------------------------------- sockets

/// Default WebSocket subprotocol offered upstream. OCPP-J stations use `ocpp1.6`.
pub const default_subprotocol: []const u8 = "ocpp1.6";

/// Network read buffer, sized to hold the largest relayable frame since
/// `readFrameBytes` peeks a whole frame at once.
const read_buffer_bytes = max_frame_bytes;
/// Outgoing buffer; writes larger than this drain straight through.
const write_buffer_bytes = 64 * 1024;

/// Read one HTTP head (request/status line + headers) up to and including the
/// terminating blank line. Bounded by `ws.max_handshake_bytes`.
fn readHead(gpa: std.mem.Allocator, r: *std.Io.Reader) ![]u8 {
    var head: std.ArrayList(u8) = .empty;
    errdefer head.deinit(gpa);
    while (true) {
        const line = try r.takeDelimiterInclusive('\n');
        try head.appendSlice(gpa, line);
        if (head.items.len > ws.max_handshake_bytes) return error.HandshakeTooLarge;
        if (std.mem.eql(u8, line, "\r\n") or std.mem.eql(u8, line, "\n")) break;
    }
    return head.toOwnedSlice(gpa);
}

/// The request-target from an HTTP request line (`GET <path> HTTP/1.1`).
fn requestPath(req: []const u8) ?[]const u8 {
    const eol = std.mem.indexOf(u8, req, "\r\n") orelse return null;
    var it = std.mem.tokenizeScalar(u8, req[0..eol], ' ');
    _ = it.next() orelse return null; // method
    return it.next();
}

/// A deterministic per-session client nonce, derived from the CP's own key. Not
/// a secret (see `relayHandshake`); deterministic so tests can reproduce the
/// proxy's upstream key and precompute the matching accept token.
fn sessionNonce(cp_key: []const u8) [16]u8 {
    var nonce: [16]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(std.hash.Wyhash.hash(0, cp_key));
    prng.random().bytes(&nonce);
    return nonce;
}

/// The MITM opening handshake: two independent RFC 6455 handshakes, one per peer.
/// Studio is the *server* to the CP (accepts its key) and the *client* to the
/// CSMS (sends its own key, validates the reply), mirroring the CP's request path
/// upstream. Reuses the #54 codec's both-halves API.
fn relayHandshake(
    gpa: std.mem.Allocator,
    cp_r: *std.Io.Reader,
    cp_w: *std.Io.Writer,
    csms_r: *std.Io.Reader,
    csms_w: *std.Io.Writer,
    upstream_host: []const u8,
    subprotocol: ?[]const u8,
) !void {
    const cp_req = try readHead(gpa, cp_r);
    defer gpa.free(cp_req);
    const cp_hs = try ws.parseClientHandshake(cp_req);
    const path = requestPath(cp_req) orelse "/";

    // The client-handshake key is fresh per session but not a secret (the peer
    // only echoes it in the accept token); it is derived deterministically from
    // the CP's own key (`sessionNonce`), which also lets tests reproduce it.
    const our_key = ws.clientKey(sessionNonce(cp_hs.key));
    const upstream_req = try ws.writeClientHandshake(gpa, upstream_host, path, our_key, subprotocol);
    defer gpa.free(upstream_req);
    try csms_w.writeAll(upstream_req);
    try csms_w.flush();

    const csms_resp = try readHead(gpa, csms_r);
    defer gpa.free(csms_resp);
    try ws.parseServerHandshake(csms_resp, our_key);

    const accept = try ws.writeServerAccept(gpa, cp_hs.key);
    defer gpa.free(accept);
    try cp_w.writeAll(accept);
    try cp_w.flush();
}

/// Relay a full session over two already-connected streams: the MITM handshake,
/// then both frame-pump directions concurrently. Each direction blocks on reads,
/// so they must truly run in parallel — `io.concurrent`, not `io.async`. The
/// shared `sink` is mutex-guarded for the duration; when one side closes, the
/// other direction is cancelled so the session tears down cleanly.
pub fn relayStreams(
    io: std.Io,
    gpa: std.mem.Allocator,
    cp_r: *std.Io.Reader,
    cp_w: *std.Io.Writer,
    cs_r: *std.Io.Reader,
    cs_w: *std.Io.Writer,
    upstream_host: []const u8,
    sink: *Sink,
    time: TimeSource,
) !void {
    try relayHandshake(gpa, cp_r, cp_w, cs_r, cs_w, upstream_host, default_subprotocol);

    var mutex: std.Io.Mutex = .init;
    sink.mutex = &mutex;
    sink.io = io;
    defer {
        sink.mutex = null;
        sink.io = null;
    }

    // CP→CSMS runs concurrently; CSMS→CP runs inline. When the inline side ends
    // (its peer closed), cancel unblocks the other's pending read.
    var up = try io.concurrent(pumpDirection, .{ gpa, cp_r, cs_w, Direction.cs_to_csms, sink, time });
    pumpDirection(gpa, cs_r, cp_w, Direction.csms_to_cs, sink, time) catch {};
    up.cancel(io) catch {};
}

/// Listen for one downstream charge point, dial the upstream CSMS, and relay the
/// session over real sockets. Single-session: returns when the session ends.
/// `listen_addr` / `upstream_addr` are resolved addresses; `upstream_host` is the
/// Host header sent upstream. The relay logic itself is `relayStreams`, driven
/// here over socket reader/writers (and in-memory ones under test).
pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    listen_addr: net.IpAddress,
    upstream_addr: net.IpAddress,
    upstream_host: []const u8,
    sink: *Sink,
    time: TimeSource,
) !void {
    var server = try listen_addr.listen(io, .{});
    defer server.deinit(io);
    const cp = try server.accept(io);
    defer cp.close(io);
    const csms = try upstream_addr.connect(io, .{ .mode = .stream });
    defer csms.close(io);

    const rbuf_cp = try gpa.alloc(u8, read_buffer_bytes);
    defer gpa.free(rbuf_cp);
    const rbuf_cs = try gpa.alloc(u8, read_buffer_bytes);
    defer gpa.free(rbuf_cs);
    const wbuf_cp = try gpa.alloc(u8, write_buffer_bytes);
    defer gpa.free(wbuf_cp);
    const wbuf_cs = try gpa.alloc(u8, write_buffer_bytes);
    defer gpa.free(wbuf_cs);

    var cp_reader = cp.reader(io, rbuf_cp);
    var cp_writer = cp.writer(io, wbuf_cp);
    var cs_reader = csms.reader(io, rbuf_cs);
    var cs_writer = csms.writer(io, wbuf_cs);
    try relayStreams(io, gpa, &cp_reader.interface, &cp_writer.interface, &cs_reader.interface, &cs_writer.interface, upstream_host, sink, time);
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

const test_ms: i64 = 1_705_312_800_000; // fixed epoch-ms ≥ 10^12

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

    try pumpDirection(gpa, &src, &dst, .cs_to_csms, &sink, .{ .fixed = test_ms });

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

    try pumpDirection(gpa, &src, &dst, .csms_to_cs, &sink, .{ .fixed = test_ms });

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
        try sink.ingest(m, origin, test_ms);
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

test "in-process relay: MITM handshake, concurrent pump, record re-parses and re-detects identically" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cp_key = ws.clientKey([_]u8{ 3, 1, 4, 1, 5, 9, 2, 6, 5, 3, 5, 8, 9, 7, 9, 3 });
    const mask = [4]u8{ 0xa1, 0xb2, 0xc3, 0xd4 };

    // The CP's wire: opening request, two masked Calls, a close.
    var cp_wire: std.ArrayList(u8) = .empty;
    defer cp_wire.deinit(gpa);
    try cp_wire.appendSlice(gpa, try ws.writeClientHandshake(arena, "studio.local", "/ocpp/CP1", cp_key, "ocpp1.6"));
    inline for (.{ "[2,\"m1\",\"BootNotification\",{\"chargePointVendor\":\"Acme\"}]", "[2,\"m2\",\"Heartbeat\",{}]" }) |call| {
        try cp_wire.appendSlice(gpa, try ws.encodeFrameAlloc(arena, true, .text, call, mask));
    }
    try cp_wire.appendSlice(gpa, try ws.encodeFrameAlloc(arena, true, .close, &[_]u8{ 0x03, 0xe8 }, mask));

    // The CSMS's wire: a 101 carrying accept() for the proxy's *deterministic*
    // upstream key (sessionNonce), two unmasked Results, a close.
    const our_key = ws.clientKey(sessionNonce(&cp_key));
    const our_accept = ws.acceptToken(&our_key);
    var cs_wire: std.ArrayList(u8) = .empty;
    defer cs_wire.deinit(gpa);
    try cs_wire.appendSlice(gpa, try std.fmt.allocPrint(arena, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{our_accept[0..]}));
    inline for (.{ "[3,\"m1\",{\"status\":\"Accepted\"}]", "[3,\"m2\",{}]" }) |res| {
        try cs_wire.appendSlice(gpa, try ws.encodeFrameAlloc(arena, true, .text, res, null));
    }
    try cs_wire.appendSlice(gpa, try ws.encodeFrameAlloc(arena, true, .close, &[_]u8{ 0x03, 0xe8 }, null));

    var cp_r = std.Io.Reader.fixed(cp_wire.items);
    var cs_r = std.Io.Reader.fixed(cs_wire.items);
    var cp_out: [8192]u8 = undefined;
    var cs_out: [8192]u8 = undefined;
    var cp_w = std.Io.Writer.fixed(&cp_out);
    var cs_w = std.Io.Writer.fixed(&cs_out);

    var rec_buf: [16384]u8 = undefined;
    var rec = std.Io.Writer.fixed(&rec_buf);
    var sink = Sink{ .gpa = arena, .record = &rec };
    defer sink.deinit();

    try relayStreams(io, arena, &cp_r, &cp_w, &cs_r, &cs_w, "csms.local", &sink, .{ .fixed = test_ms });

    // Relay correctness: the CSMS-facing side carries the proxy's client handshake
    // (mirroring the CP's path); the CP-facing side got a 101 accept.
    try testing.expect(std.mem.indexOf(u8, cs_w.buffered(), "GET /ocpp/CP1 HTTP/1.1") != null);
    try testing.expect(std.mem.startsWith(u8, cp_w.buffered(), "HTTP/1.1 101"));

    // The tap captured all four messages; the recording re-parses to four events.
    try testing.expectEqual(@as(usize, 4), sink.count());
    const reparsed = try ocpp.parser.parseTrace(arena, rec.buffered());
    try testing.expectEqual(@as(usize, 4), reparsed.events.len);

    // Streaming detection equals a cold offline pass over the recording.
    const live = try sink.detect(arena);
    const sessions = try timeline.buildSessionTimeline(arena, reparsed.events);
    const offline = try detection.detectFailures(arena, reparsed.events, sessions);
    try testing.expectEqual(offline.len, live.len);
    for (live, offline) |lf, off| try testing.expectEqual(off.code, lf.code);
}

test "run() socket wiring is analyzed" {
    // `run` is only reached via itself (the CLI wires it in #57), so reference it
    // to force Zig to compile its socket accept/dial path — lazy analysis would
    // otherwise skip it in both the test and the app build.
    _ = &run;
}

test "TimeSource.wall reads a plausible epoch-ms from the io clock" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const ms = (TimeSource{ .wall = io }).nowMs().?;
    try testing.expect(ms > 1_600_000_000_000); // after 2020-09
    try testing.expectEqual(@as(?i64, null), (TimeSource{ .none = {} }).nowMs());
    try testing.expectEqual(@as(?i64, 42), (TimeSource{ .fixed = 42 }).nowMs());
}
