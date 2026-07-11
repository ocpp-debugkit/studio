//! Replay engine — step through a trace's events in order, exposing the
//! failures detected at each position.
//!
//! Mirrors the toolkit's `replay/engine.ts`, which is deliberately **timer-free**
//! and deterministic: the consumer drives it with `step` / `stepBack` / `jumpTo`.
//! This is the parity core. Real wall-clock auto-playback (advancing on a clock
//! at a speed multiplier) needs a timer source the zero-config runner does not
//! expose, so it is deferred to the runner-eject bucket (#33); `speed` is carried
//! here for that future consumer but the pure engine never acts on it.
//!
//! Pure and headless; per-position `failures` slices are allocated from the
//! caller's allocator.

const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

/// A single replayed event and the failures implicating it.
pub const ReplayEvent = struct {
    event: types.Event,
    /// Failures whose `event_ids` include this event's id.
    failures: []const types.Failure,
    /// Zero-based index in the original event array.
    index: usize,
};

/// A snapshot of replay progress.
pub const ReplayState = struct {
    played: []const ReplayEvent,
    remaining: []const types.Event,
    complete: bool,
};

/// Construction options. `speed` (playback multiplier) is stored for the future
/// wall-clock consumer; `start_index` seeds the cursor.
pub const ReplayOptions = struct {
    speed: f64 = 1.0,
    start_index: usize = 0,
};

/// Deterministic replay cursor over a trace. No timers, no I/O.
pub const ReplayEngine = struct {
    events: []const types.Event,
    failures: []const types.Failure,
    current_index: usize,
    speed: f64,

    pub fn init(events: []const types.Event, failures: []const types.Failure, options: ReplayOptions) ReplayEngine {
        return .{
            .events = events,
            .failures = failures,
            .current_index = options.start_index,
            .speed = options.speed,
        };
    }

    /// Total number of events.
    pub fn totalEvents(self: *const ReplayEngine) usize {
        return self.events.len;
    }

    /// Current 0-based cursor, or null when there are no events (the toolkit's
    /// `current` returns -1 in that case).
    pub fn current(self: *const ReplayEngine) ?usize {
        return if (self.events.len == 0) null else self.current_index;
    }

    /// Step forward one event. Returns the replay event, or null if complete.
    pub fn step(self: *ReplayEngine, gpa: Allocator) !?ReplayEvent {
        if (self.current_index >= self.events.len) return null;
        const event = self.events[self.current_index];
        const index = self.current_index;
        const failures = try failuresFor(gpa, self.failures, event.id);
        self.current_index += 1;
        return .{ .event = event, .failures = failures, .index = index };
    }

    /// Step backward one event. Returns the replay event, or null if at the start.
    /// Mirrors the toolkit: rewind two then step forward one (net −1).
    pub fn stepBack(self: *ReplayEngine, gpa: Allocator) !?ReplayEvent {
        if (self.current_index <= 1) return null;
        self.current_index -= 2;
        return self.step(gpa);
    }

    /// Jump to `index` and play it. Returns the replay event, or null if out of
    /// range (index is unsigned, so only the upper bound can fail).
    pub fn jumpTo(self: *ReplayEngine, gpa: Allocator, index: usize) !?ReplayEvent {
        if (index >= self.events.len) return null;
        self.current_index = index;
        return self.step(gpa);
    }

    /// Snapshot: events played so far, events remaining, and completion.
    pub fn getState(self: *const ReplayEngine, gpa: Allocator) !ReplayState {
        var played: std.ArrayList(ReplayEvent) = .empty;
        const upto = @min(self.current_index, self.events.len);
        var i: usize = 0;
        while (i < upto) : (i += 1) {
            const event = self.events[i];
            try played.append(gpa, .{
                .event = event,
                .failures = try failuresFor(gpa, self.failures, event.id),
                .index = i,
            });
        }
        return .{
            .played = try played.toOwnedSlice(gpa),
            .remaining = self.events[upto..],
            .complete = self.current_index >= self.events.len,
        };
    }

    /// Reset the cursor to the beginning.
    pub fn reset(self: *ReplayEngine) void {
        self.current_index = 0;
    }
};

/// The failures whose `event_ids` include `event_id`, allocated from `gpa`.
fn failuresFor(gpa: Allocator, failures: []const types.Failure, event_id: []const u8) ![]const types.Failure {
    var out: std.ArrayList(types.Failure) = .empty;
    for (failures) |f| {
        for (f.event_ids) |id| {
            if (std.mem.eql(u8, id, event_id)) {
                try out.append(gpa, f);
                break;
            }
        }
    }
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A minimal Call event with the given id (enough to drive the cursor).
fn mkEvent(id: []const u8) types.Event {
    return .{
        .id = id,
        .message_id = id,
        .timestamp = null,
        .direction = .cs_to_csms,
        .message_type = .call,
        .action = "Heartbeat",
        .payload = .null,
        .error_code = null,
        .error_description = null,
        .raw_message = .null,
    };
}

fn sampleEvents() [3]types.Event {
    return .{ mkEvent("evt-1"), mkEvent("evt-2"), mkEvent("evt-3") };
}

fn sampleFailures() [1]types.Failure {
    return .{.{
        .code = .slow_response,
        .description = "slow",
        .severity = .warning,
        .event_ids = &.{"evt-2"},
        .suggested_steps = &.{},
    }};
}

test "step walks every event in order with failures attached at position" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const events = sampleEvents();
    const failures = sampleFailures();
    var engine = ReplayEngine.init(&events, &failures, .{});

    try testing.expectEqual(@as(usize, 3), engine.totalEvents());

    const r0 = (try engine.step(a)).?;
    try testing.expectEqual(@as(usize, 0), r0.index);
    try testing.expectEqualStrings("evt-1", r0.event.id);
    try testing.expectEqual(@as(usize, 0), r0.failures.len);

    const r1 = (try engine.step(a)).?;
    try testing.expectEqual(@as(usize, 1), r1.index);
    try testing.expectEqual(@as(usize, 1), r1.failures.len); // slow_response touches evt-2
    try testing.expectEqual(types.FailureCode.slow_response, r1.failures[0].code);

    const r2 = (try engine.step(a)).?;
    try testing.expectEqual(@as(usize, 2), r2.index);
    try testing.expectEqual(@as(usize, 0), r2.failures.len);

    // Past the end → null, cursor doesn't run away.
    try testing.expectEqual(@as(?ReplayEvent, null), try engine.step(a));
}

test "stepBack rewinds one net event; null at the start" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const events = sampleEvents();
    var engine = ReplayEngine.init(&events, &.{}, .{});

    _ = try engine.step(a); // index 0, cursor 1
    _ = try engine.step(a); // index 1, cursor 2
    _ = try engine.step(a); // index 2, cursor 3

    const b1 = (try engine.stepBack(a)).?; // cursor 3 → 1, plays index 1
    try testing.expectEqual(@as(usize, 1), b1.index);
    const b2 = (try engine.stepBack(a)).?; // cursor 2 → 0, plays index 0
    try testing.expectEqual(@as(usize, 0), b2.index);

    // cursor is now 1: stepBack (<= 1) refuses to rewind past the start.
    try testing.expectEqual(@as(?ReplayEvent, null), try engine.stepBack(a));
}

test "jumpTo plays the target and rejects out-of-range" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const events = sampleEvents();
    var engine = ReplayEngine.init(&events, &.{}, .{});

    const j = (try engine.jumpTo(a, 2)).?;
    try testing.expectEqual(@as(usize, 2), j.index);
    try testing.expectEqualStrings("evt-3", j.event.id);
    try testing.expectEqual(@as(?ReplayEvent, null), try engine.jumpTo(a, 3));
    try testing.expectEqual(@as(?ReplayEvent, null), try engine.jumpTo(a, 99));
}

test "getState reports played, remaining, and completion" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const events = sampleEvents();
    var engine = ReplayEngine.init(&events, &.{}, .{});

    const s0 = try engine.getState(a);
    try testing.expectEqual(@as(usize, 0), s0.played.len);
    try testing.expectEqual(@as(usize, 3), s0.remaining.len);
    try testing.expect(!s0.complete);

    _ = try engine.step(a);
    _ = try engine.step(a);
    const s2 = try engine.getState(a);
    try testing.expectEqual(@as(usize, 2), s2.played.len);
    try testing.expectEqual(@as(usize, 1), s2.remaining.len);
    try testing.expect(!s2.complete);

    _ = try engine.step(a);
    const s3 = try engine.getState(a);
    try testing.expectEqual(@as(usize, 3), s3.played.len);
    try testing.expectEqual(@as(usize, 0), s3.remaining.len);
    try testing.expect(s3.complete);
}

test "reset returns to the start; start_index seeds the cursor" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const events = sampleEvents();
    var engine = ReplayEngine.init(&events, &.{}, .{ .start_index = 2, .speed = 2.0 });
    try testing.expectEqual(@as(?usize, 2), engine.current());
    try testing.expectEqual(@as(f64, 2.0), engine.speed);

    const first = (try engine.step(a)).?;
    try testing.expectEqual(@as(usize, 2), first.index); // seeded at index 2

    engine.reset();
    try testing.expectEqual(@as(?usize, 0), engine.current());
    const after_reset = (try engine.step(a)).?;
    try testing.expectEqual(@as(usize, 0), after_reset.index);
}

test "empty trace: current is null, step yields nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var engine = ReplayEngine.init(&.{}, &.{}, .{});
    try testing.expectEqual(@as(?usize, null), engine.current());
    try testing.expectEqual(@as(usize, 0), engine.totalEvents());
    try testing.expectEqual(@as(?ReplayEvent, null), try engine.step(a));

    const s = try engine.getState(a);
    try testing.expect(s.complete);
    try testing.expectEqual(@as(usize, 0), s.played.len);
}
