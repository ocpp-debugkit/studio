//! Minimal, hardened RFC 6455 WebSocket codec (ADR-0008).
//!
//! Studio's live-capture proxy is a man-in-the-middle: a WebSocket **server** to
//! the downstream charge point and a **client** to the upstream CSMS. So this
//! module implements both handshake halves and both masking rules.
//!
//! It is a *codec*, not a transport: every function operates on byte buffers, so
//! the whole thing is unit-testable without a socket. Socket I/O and the proxy
//! loop live in `proxy.zig` (#56).
//!
//! Scope (ADR-0008): the RFC 6455 core — opening handshake, base framing,
//! fragmentation, control frames. Out of scope: `permessage-deflate` and TLS
//! (the post-0.5 secure-profile work, behind this same boundary).
//!
//! Hardening: this is the rawest untrusted-input entry point in Studio — bytes
//! arrive from an arbitrary peer. Frame and message sizes are bounded, masking
//! rules are enforced (client→server MUST be masked, server→client MUST NOT),
//! and reserved bits, unknown opcodes, and malformed control frames are rejected.

const std = @import("std");

/// RFC 6455 §1.3 — the GUID appended to `Sec-WebSocket-Key` before hashing.
pub const magic_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// Hard bounds. The proxy forwards frames verbatim, so these cap per-frame and
/// per-message work; a hostile peer cannot drive unbounded allocation. Generous
/// enough for real OCPP-J traffic (payloads are small JSON arrays).
pub const max_frame_payload: usize = 16 * 1024 * 1024; // 16 MiB per frame
pub const max_message_bytes: usize = 32 * 1024 * 1024; // 32 MiB reassembled
pub const max_fragments: usize = 1024; // continuation frames per message
pub const max_handshake_bytes: usize = 16 * 1024; // opening handshake head

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xa,
    _,

    /// RFC 6455 §5.6: opcodes with the high bit set are control frames.
    pub fn isControl(op: Opcode) bool {
        return (@intFromEnum(op) & 0x8) != 0;
    }
};

pub const ProtocolError = error{
    ReservedBitSet,
    UnknownOpcode,
    MaskingViolation,
    ControlFrameTooLong,
    FragmentedControlFrame,
    FramePayloadTooLarge,
    MessageTooLarge,
    TooManyFragments,
    UnexpectedContinuation,
    UnexpectedOpcode,
};

pub const HandshakeError = error{
    NotAWebSocketUpgrade,
    MissingKey,
    BadStatus,
    BadAccept,
};

// ------------------------------------------------------------------ handshake

/// `base64(SHA1(key ++ magic_guid))` — the RFC 6455 §4.2.2 server accept token.
/// SHA-1 is 20 bytes, whose standard base64 is exactly 28 characters.
pub fn acceptToken(key: []const u8) [28]u8 {
    var sha: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    var h = std.crypto.hash.Sha1.init(.{});
    h.update(key);
    h.update(magic_guid);
    h.final(&sha);
    var out: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&out, &sha);
    return out;
}

/// `Sec-WebSocket-Key` for the client half: base64 of a 16-byte nonce. The
/// nonce is supplied by the caller (drawn from a CSPRNG at the socket layer) so
/// this codec stays pure and deterministic under test.
pub fn clientKey(nonce: [16]u8) [24]u8 {
    var out: [24]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&out, &nonce);
    return out;
}

pub const ClientHandshake = struct {
    /// `Sec-WebSocket-Key` value, borrowing the input buffer.
    key: []const u8,
};

/// Parse a downstream charge point's opening request (server half). Validates it
/// is a WebSocket upgrade and extracts the key. Bytes are untrusted.
pub fn parseClientHandshake(bytes: []const u8) HandshakeError!ClientHandshake {
    const head = headEnd(bytes) orelse return error.NotAWebSocketUpgrade;
    if (!std.mem.startsWith(u8, bytes, "GET ")) return error.NotAWebSocketUpgrade;
    const upgrade = headerValue(head, "upgrade") orelse return error.NotAWebSocketUpgrade;
    if (!containsIgnoreCase(upgrade, "websocket")) return error.NotAWebSocketUpgrade;
    const conn = headerValue(head, "connection") orelse return error.NotAWebSocketUpgrade;
    if (!containsIgnoreCase(conn, "upgrade")) return error.NotAWebSocketUpgrade;
    const key = headerValue(head, "sec-websocket-key") orelse return error.MissingKey;
    return .{ .key = key };
}

/// Build the server's `101 Switching Protocols` response for `key`.
pub fn writeServerAccept(gpa: std.mem.Allocator, key: []const u8) ![]u8 {
    const accept = acceptToken(key);
    return std.fmt.allocPrint(
        gpa,
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: {s}\r\n\r\n",
        .{accept[0..]},
    );
}

/// Build the client's opening request for the upstream CSMS (client half).
pub fn writeClientHandshake(
    gpa: std.mem.Allocator,
    host: []const u8,
    path: []const u8,
    key: [24]u8,
    subprotocol: ?[]const u8,
) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    errdefer b.deinit(gpa);
    try b.appendSlice(gpa, "GET ");
    try b.appendSlice(gpa, path);
    try b.appendSlice(gpa, " HTTP/1.1\r\nHost: ");
    try b.appendSlice(gpa, host);
    try b.appendSlice(gpa, "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ");
    try b.appendSlice(gpa, &key);
    try b.appendSlice(gpa, "\r\nSec-WebSocket-Version: 13\r\n");
    if (subprotocol) |sp| {
        try b.appendSlice(gpa, "Sec-WebSocket-Protocol: ");
        try b.appendSlice(gpa, sp);
        try b.appendSlice(gpa, "\r\n");
    }
    try b.appendSlice(gpa, "\r\n");
    return b.toOwnedSlice(gpa);
}

/// Validate the upstream CSMS's `101` response against the key we sent.
pub fn parseServerHandshake(bytes: []const u8, expected_key: [24]u8) HandshakeError!void {
    const head = headEnd(bytes) orelse return error.BadStatus;
    if (!std.mem.startsWith(u8, bytes, "HTTP/1.1 101")) return error.BadStatus;
    const accept = headerValue(head, "sec-websocket-accept") orelse return error.BadAccept;
    const expected = acceptToken(&expected_key);
    if (!std.mem.eql(u8, accept, expected[0..])) return error.BadAccept;
}

fn headEnd(bytes: []const u8) ?[]const u8 {
    const idx = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse return null;
    if (idx > max_handshake_bytes) return null;
    return bytes[0..idx];
}

/// Case-insensitive header lookup over the head (request/status line + headers,
/// CRLF-separated). Returns the trimmed value of the first matching field.
fn headerValue(head: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, head, "\r\n");
    _ = it.next(); // request / status line
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const k = std.mem.trim(u8, line[0..colon], " \t");
        if (std.ascii.eqlIgnoreCase(k, name)) return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

// --------------------------------------------------------------------- framing

pub const Frame = struct {
    fin: bool,
    opcode: Opcode,
    /// Unmasked payload. On a masked frame `decodeFrame` unmasks in place, so
    /// this borrows the decode buffer.
    payload: []const u8,
};

pub const Decoded = struct {
    frame: Frame,
    /// Total bytes consumed from the front of the input buffer.
    consumed: usize,
};

/// Decode one frame from the front of `buf`. Returns `null` when `buf` does not
/// yet hold a complete frame (the caller reads more and retries). A masked frame
/// is unmasked in place, so `buf` must be mutable and the returned payload
/// borrows it. `expect_masked` enforces the role's masking rule — a server
/// decoding client frames passes `true`; a client decoding server frames `false`.
pub fn decodeFrame(buf: []u8, expect_masked: bool) ProtocolError!?Decoded {
    if (buf.len < 2) return null;
    const b0 = buf[0];
    const b1 = buf[1];

    if ((b0 & 0x70) != 0) return error.ReservedBitSet; // RSV1..3 unsupported
    const fin = (b0 & 0x80) != 0;
    const opcode: Opcode = @enumFromInt(@as(u4, @truncate(b0 & 0x0f)));
    switch (opcode) {
        .continuation, .text, .binary, .close, .ping, .pong => {},
        else => return error.UnknownOpcode,
    }

    const masked = (b1 & 0x80) != 0;
    var len: u64 = b1 & 0x7f;
    var off: usize = 2;
    if (len == 126) {
        if (buf.len < off + 2) return null;
        len = std.mem.readInt(u16, buf[off..][0..2], .big);
        off += 2;
    } else if (len == 127) {
        if (buf.len < off + 8) return null;
        len = std.mem.readInt(u64, buf[off..][0..8], .big);
        off += 8;
    }

    if (opcode.isControl()) {
        if (!fin) return error.FragmentedControlFrame;
        if (len > 125) return error.ControlFrameTooLong;
    }
    if (len > max_frame_payload) return error.FramePayloadTooLarge;
    if (masked != expect_masked) return error.MaskingViolation;

    var mask: [4]u8 = undefined;
    if (masked) {
        if (buf.len < off + 4) return null;
        mask = buf[off..][0..4].*;
        off += 4;
    }

    const payload_len: usize = @intCast(len);
    if (buf.len < off + payload_len) return null;
    const payload = buf[off .. off + payload_len];
    if (masked) {
        for (payload, 0..) |*p, i| p.* ^= mask[i & 3];
    }
    return .{
        .frame = .{ .fin = fin, .opcode = opcode, .payload = payload },
        .consumed = off + payload_len,
    };
}

/// Bytes an encoded frame occupies, given payload length and whether it's masked.
pub fn frameSize(payload_len: usize, masked: bool) usize {
    var n: usize = 2;
    if (payload_len > 65535) n += 8 else if (payload_len > 125) n += 2;
    if (masked) n += 4;
    return n + payload_len;
}

/// Encode a frame into `out`. When `mask` is non-null (client role) the payload
/// is masked with it. Returns bytes written.
pub fn encodeFrame(
    out: []u8,
    fin: bool,
    opcode: Opcode,
    payload: []const u8,
    mask: ?[4]u8,
) error{ FramePayloadTooLarge, NoSpaceLeft }!usize {
    if (payload.len > max_frame_payload) return error.FramePayloadTooLarge;
    const total = frameSize(payload.len, mask != null);
    if (out.len < total) return error.NoSpaceLeft;

    out[0] = (if (fin) @as(u8, 0x80) else 0) | @as(u8, @intFromEnum(opcode));
    const masked_bit: u8 = if (mask != null) 0x80 else 0;
    var off: usize = 2;
    if (payload.len > 65535) {
        out[1] = masked_bit | 127;
        std.mem.writeInt(u64, out[2..][0..8], payload.len, .big);
        off = 10;
    } else if (payload.len > 125) {
        out[1] = masked_bit | 126;
        std.mem.writeInt(u16, out[2..][0..2], @intCast(payload.len), .big);
        off = 4;
    } else {
        out[1] = masked_bit | @as(u8, @intCast(payload.len));
    }

    if (mask) |m| {
        out[off..][0..4].* = m;
        off += 4;
        for (payload, 0..) |p, i| out[off + i] = p ^ m[i & 3];
    } else {
        @memcpy(out[off..][0..payload.len], payload);
    }
    return total;
}

/// Allocate-and-encode convenience for tests and the proxy's send path.
pub fn encodeFrameAlloc(
    gpa: std.mem.Allocator,
    fin: bool,
    opcode: Opcode,
    payload: []const u8,
    mask: ?[4]u8,
) error{ FramePayloadTooLarge, OutOfMemory }![]u8 {
    if (payload.len > max_frame_payload) return error.FramePayloadTooLarge;
    const out = try gpa.alloc(u8, frameSize(payload.len, mask != null));
    errdefer gpa.free(out);
    _ = encodeFrame(out, fin, opcode, payload, mask) catch |err| switch (err) {
        error.NoSpaceLeft => unreachable, // sized exactly above
        error.FramePayloadTooLarge => return error.FramePayloadTooLarge,
    };
    return out;
}

// -------------------------------------------------------------- close frames

/// Build a close frame body (`code` + optional `reason`) into `out`.
pub fn encodeClose(
    out: []u8,
    code: u16,
    reason: []const u8,
    mask: ?[4]u8,
) error{ ControlFrameTooLong, NoSpaceLeft }!usize {
    if (2 + reason.len > 125) return error.ControlFrameTooLong;
    var body: [125]u8 = undefined;
    std.mem.writeInt(u16, body[0..2], code, .big);
    @memcpy(body[2 .. 2 + reason.len], reason);
    return encodeFrame(out, true, .close, body[0 .. 2 + reason.len], mask) catch |err| switch (err) {
        error.NoSpaceLeft => error.NoSpaceLeft,
        error.FramePayloadTooLarge => unreachable, // ≤125 bytes
    };
}

pub const Close = struct { code: u16, reason: []const u8 };

/// Parse a close frame's unmasked payload. An empty payload is a code-less close.
pub fn parseClose(payload: []const u8) Close {
    if (payload.len < 2) return .{ .code = 1005, .reason = "" }; // 1005: no status
    return .{ .code = std.mem.readInt(u16, payload[0..2], .big), .reason = payload[2..] };
}

// ------------------------------------------------------------- reassembly

pub const Message = struct { opcode: Opcode, payload: []const u8 };

/// Reassembles a fragmented data message from its frames. Control frames may
/// interleave a fragmented message and are handled by the caller — they never
/// go through the assembler.
pub const Assembler = struct {
    buf: std.ArrayList(u8) = .empty,
    opcode: ?Opcode = null,
    fragments: usize = 0,

    pub fn deinit(self: *Assembler, gpa: std.mem.Allocator) void {
        self.buf.deinit(gpa);
    }

    /// Feed one **data** frame. Returns a complete `Message` (borrowing the
    /// assembler's buffer until the next `push`) when `fin` closes the message,
    /// else `null`.
    pub fn push(
        self: *Assembler,
        gpa: std.mem.Allocator,
        frame: Frame,
    ) (std.mem.Allocator.Error || ProtocolError)!?Message {
        std.debug.assert(!frame.opcode.isControl());
        if (self.opcode == null) {
            if (frame.opcode == .continuation) return error.UnexpectedContinuation;
            self.opcode = frame.opcode;
            self.fragments = 0;
            self.buf.clearRetainingCapacity();
        } else if (frame.opcode != .continuation) {
            return error.UnexpectedOpcode;
        }

        self.fragments += 1;
        if (self.fragments > max_fragments) return error.TooManyFragments;
        if (self.buf.items.len + frame.payload.len > max_message_bytes) return error.MessageTooLarge;
        try self.buf.appendSlice(gpa, frame.payload);

        if (!frame.fin) return null;
        const op = self.opcode.?;
        self.opcode = null;
        return .{ .opcode = op, .payload = self.buf.items };
    }
};

// ------------------------------------------------------------------- tests

const testing = std.testing;

test "acceptToken matches the RFC 6455 example" {
    // RFC 6455 §1.3.
    const got = acceptToken("dGhlIHNhbXBsZSBub25jZQ==");
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", got[0..]);
}

test "clientKey is base64 of the 16-byte nonce" {
    const key = clientKey([_]u8{0} ** 16);
    try testing.expectEqualStrings("AAAAAAAAAAAAAAAAAAAAAA==", key[0..]);
}

test "handshake round-trips through both halves" {
    const gpa = testing.allocator;
    const key = clientKey([_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 });

    const req = try writeClientHandshake(gpa, "csms.example:9000", "/ocpp/CP01", key, "ocpp1.6");
    defer gpa.free(req);
    const parsed = try parseClientHandshake(req);
    try testing.expectEqualStrings(key[0..], parsed.key);

    const resp = try writeServerAccept(gpa, parsed.key);
    defer gpa.free(resp);
    try parseServerHandshake(resp, key);
}

test "parseServerHandshake rejects a mismatched accept" {
    const gpa = testing.allocator;
    const resp = try writeServerAccept(gpa, "some-other-key");
    defer gpa.free(resp);
    try testing.expectError(error.BadAccept, parseServerHandshake(resp, clientKey([_]u8{9} ** 16)));
}

test "parseClientHandshake rejects a non-upgrade request" {
    try testing.expectError(
        error.NotAWebSocketUpgrade,
        parseClientHandshake("GET / HTTP/1.1\r\nHost: x\r\n\r\n"),
    );
}

test "frame round-trips at each length form, unmasked and masked" {
    const gpa = testing.allocator;
    const mask = [4]u8{ 0xde, 0xad, 0xbe, 0xef };
    for ([_]usize{ 5, 200, 70_000 }) |n| {
        const payload = try gpa.alloc(u8, n);
        defer gpa.free(payload);
        for (payload, 0..) |*p, i| p.* = @intCast(i & 0xff);

        // Unmasked (server→client).
        {
            const wire = try encodeFrameAlloc(gpa, true, .binary, payload, null);
            defer gpa.free(wire);
            const dec = (try decodeFrame(wire, false)).?;
            try testing.expect(dec.frame.fin);
            try testing.expectEqual(Opcode.binary, dec.frame.opcode);
            try testing.expectEqualSlices(u8, payload, dec.frame.payload);
            try testing.expectEqual(wire.len, dec.consumed);
        }
        // Masked (client→server): on-wire bytes differ; decode restores them.
        {
            const wire = try encodeFrameAlloc(gpa, true, .binary, payload, mask);
            defer gpa.free(wire);
            const hdr = frameSize(n, true) - n;
            try testing.expect(!std.mem.eql(u8, wire[hdr..], payload));
            const dec = (try decodeFrame(wire, true)).?;
            try testing.expectEqualSlices(u8, payload, dec.frame.payload);
        }
    }
}

test "decodeFrame enforces the masking rule for the role" {
    const gpa = testing.allocator;
    const unmasked = try encodeFrameAlloc(gpa, true, .text, "hi", null);
    defer gpa.free(unmasked);
    try testing.expectError(error.MaskingViolation, decodeFrame(unmasked, true));

    const masked = try encodeFrameAlloc(gpa, true, .text, "hi", [4]u8{ 1, 2, 3, 4 });
    defer gpa.free(masked);
    try testing.expectError(error.MaskingViolation, decodeFrame(masked, false));
}

test "decodeFrame rejects reserved bits and unknown opcodes" {
    var rsv = [_]u8{ 0xc1, 0x00 }; // RSV1 + text, no payload
    try testing.expectError(error.ReservedBitSet, decodeFrame(&rsv, false));
    var unknown = [_]u8{ 0x83, 0x00 }; // fin + opcode 0x3 (reserved data)
    try testing.expectError(error.UnknownOpcode, decodeFrame(&unknown, false));
}

test "decodeFrame rejects malformed control frames" {
    // Control frame (ping) with a 126-byte length is illegal.
    var too_long = [_]u8{ 0x89, 0x7e, 0x00, 0x7e };
    try testing.expectError(error.ControlFrameTooLong, decodeFrame(&too_long, false));
    // Fragmented control frame (FIN clear on a close).
    var fragmented = [_]u8{ 0x08, 0x00 };
    try testing.expectError(error.FragmentedControlFrame, decodeFrame(&fragmented, false));
}

test "decodeFrame rejects an oversize payload before reading it" {
    // 64-bit length claiming ~4 GiB, with no payload bytes present.
    var hdr = [_]u8{ 0x82, 0x7f, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00 };
    try testing.expectError(error.FramePayloadTooLarge, decodeFrame(&hdr, false));
}

test "decodeFrame returns null on a truncated buffer" {
    const gpa = testing.allocator;
    const wire = try encodeFrameAlloc(gpa, true, .text, "hello world", null);
    defer gpa.free(wire);
    try testing.expect((try decodeFrame(wire[0 .. wire.len - 3], false)) == null);
    try testing.expect((try decodeFrame(wire[0..1], false)) == null);
}

test "Assembler reassembles a fragmented message" {
    const gpa = testing.allocator;
    var asm_ = Assembler{};
    defer asm_.deinit(gpa);

    try testing.expect((try asm_.push(gpa, .{ .fin = false, .opcode = .text, .payload = "He" })) == null);
    try testing.expect((try asm_.push(gpa, .{ .fin = false, .opcode = .continuation, .payload = "ll" })) == null);
    const msg = (try asm_.push(gpa, .{ .fin = true, .opcode = .continuation, .payload = "o" })).?;
    try testing.expectEqual(Opcode.text, msg.opcode);
    try testing.expectEqualStrings("Hello", msg.payload);

    // A single unfragmented frame is a complete message immediately.
    const solo = (try asm_.push(gpa, .{ .fin = true, .opcode = .text, .payload = "Hi" })).?;
    try testing.expectEqualStrings("Hi", solo.payload);
}

test "Assembler rejects framing violations" {
    const gpa = testing.allocator;
    var asm_ = Assembler{};
    defer asm_.deinit(gpa);
    try testing.expectError(
        error.UnexpectedContinuation,
        asm_.push(gpa, .{ .fin = true, .opcode = .continuation, .payload = "x" }),
    );
    _ = try asm_.push(gpa, .{ .fin = false, .opcode = .text, .payload = "a" });
    try testing.expectError(
        error.UnexpectedOpcode,
        asm_.push(gpa, .{ .fin = true, .opcode = .text, .payload = "b" }),
    );
}

test "close frame round-trips" {
    var out: [64]u8 = undefined;
    const n = try encodeClose(&out, 1000, "bye", null);
    const dec = (try decodeFrame(out[0..n], false)).?;
    try testing.expectEqual(Opcode.close, dec.frame.opcode);
    const parsed = parseClose(dec.frame.payload);
    try testing.expectEqual(@as(u16, 1000), parsed.code);
    try testing.expectEqualStrings("bye", parsed.reason);
}
