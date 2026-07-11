//! The inspector's application state: a bounded workspace of open traces plus
//! the `Msg` / `update` half of the TEA loop. Pure and headless — it imports the
//! engine and the canvas message types, never a platform or window module, so it
//! tests under `-Dplatform=null` exactly like the engine does.
//!
//! Each open trace owns a private arena holding everything the engine parsed for
//! it (events, sessions, failures, and the display name). Closing a trace frees
//! that one arena; the model itself allocates nothing per rebuild — the view
//! derives display strings into the per-build UI arena (`inspector.zig`).

const std = @import("std");
const ocpp = @import("../ocpp/ocpp.zig");
const parser = ocpp.parser;
const timeline = ocpp.timeline;
const detection = ocpp.detection;
const types = ocpp.types;

/// Upper bound on simultaneously open traces (workspace tabs). A hard cap keeps
/// the tab strip and per-trace arenas bounded; opening past it is a no-op.
pub const max_open_traces: usize = 8;

/// One open trace and everything the engine derived from it. All borrowed slices
/// (`name`, `parse`, `sessions`, `failures`) live in `arena`; freeing `arena`
/// frees the whole trace. A failed load keeps its arena too (it holds `name` and
/// lets the error stay on screen) — `load_error` is non-null and the engine
/// slices are empty.
pub const LoadedTrace = struct {
    /// The private arena owning this trace's memory, or null for a slot that
    /// never allocated (an out-of-memory load failure).
    arena: ?*std.heap.ArenaAllocator = null,
    /// Display name (usually the file's basename, or the sample label).
    name: []const u8 = "",
    events: []types.Event = &.{},
    sessions: []types.Session = &.{},
    failures: []types.Failure = &.{},
    warnings: []types.ParseWarning = &.{},
    /// Non-null when the trace could not be parsed; a human-readable reason.
    load_error: ?[]const u8 = null,
    /// The timeline row the user selected, if any (wired in the timeline PR).
    selected_event: ?usize = null,

    pub fn isError(self: *const LoadedTrace) bool {
        return self.load_error != null;
    }
    pub fn eventCount(self: *const LoadedTrace) usize {
        return self.events.len;
    }
    pub fn sessionCount(self: *const LoadedTrace) usize {
        return self.sessions.len;
    }
    pub fn failureCount(self: *const LoadedTrace) usize {
        return self.failures.len;
    }
    pub fn warningCount(self: *const LoadedTrace) usize {
        return self.warnings.len;
    }
    /// Count of detected failures at the given severity.
    pub fn failuresOf(self: *const LoadedTrace, severity: types.FailureSeverity) usize {
        var n: usize = 0;
        for (self.failures) |f| {
            if (f.severity == severity) n += 1;
        }
        return n;
    }

    fn deinit(self: *LoadedTrace, backing: std.mem.Allocator) void {
        if (self.arena) |ap| {
            ap.deinit();
            backing.destroy(ap);
        }
        self.* = .{};
    }
};

pub const Msg = union(enum) {
    /// Load the built-in sample trace into the workspace.
    open_sample,
    /// Make trace `payload` the active tab.
    select_trace: usize,
    /// Close trace `payload`, freeing its arena.
    close_trace: usize,
};

pub const Model = struct {
    /// Backing allocator for per-trace arenas. Defaults to the page allocator;
    /// `main` may override it and tests inject `std.testing.allocator` so leaks
    /// surface. Every open/close balances against this exact allocator.
    backing: std.mem.Allocator = std.heap.page_allocator,
    traces: [max_open_traces]LoadedTrace = [_]LoadedTrace{.{}} ** max_open_traces,
    trace_count: usize = 0,
    /// Index of the active trace within `traces[0..trace_count]`.
    active: usize = 0,

    // --- derived (never stored) -------------------------------------------

    pub fn hasTraces(self: *const Model) bool {
        return self.trace_count > 0;
    }
    pub fn open(self: *const Model) []const LoadedTrace {
        return self.traces[0..self.trace_count];
    }
    /// The active trace, or null when the workspace is empty.
    pub fn activeTrace(self: *const Model) ?*const LoadedTrace {
        if (self.trace_count == 0) return null;
        return &self.traces[self.active];
    }

    // --- mutation ---------------------------------------------------------

    /// Parse `bytes` and append the result as a new trace, made active. Silently
    /// a no-op when the workspace is full. `name` is copied into the trace's
    /// arena, so the caller's buffer is free on return. A parse failure still
    /// appends a trace — one carrying `load_error` — so the reason is visible.
    pub fn openBytes(self: *Model, name: []const u8, bytes: []const u8) void {
        if (self.trace_count >= max_open_traces) return;
        self.traces[self.trace_count] = loadTrace(self.backing, name, bytes);
        self.active = self.trace_count;
        self.trace_count += 1;
    }

    /// Append a trace that failed before parsing (e.g. the file could not be
    /// read), so the reason is visible in the workspace like any other error.
    pub fn openLoadError(self: *Model, name: []const u8, reason: []const u8) void {
        if (self.trace_count >= max_open_traces) return;
        self.traces[self.trace_count] = errorTrace(self.backing, name, reason);
        self.active = self.trace_count;
        self.trace_count += 1;
    }

    pub fn selectTrace(self: *Model, index: usize) void {
        if (index < self.trace_count) self.active = index;
    }

    /// Close trace `index`, freeing its arena and compacting the tab list.
    pub fn closeTrace(self: *Model, index: usize) void {
        if (index >= self.trace_count) return;
        self.traces[index].deinit(self.backing);
        var i = index;
        while (i + 1 < self.trace_count) : (i += 1) {
            self.traces[i] = self.traces[i + 1];
        }
        self.trace_count -= 1;
        self.traces[self.trace_count] = .{};
        if (self.trace_count == 0) {
            self.active = 0;
        } else if (self.active >= self.trace_count) {
            self.active = self.trace_count - 1;
        } else if (self.active > index) {
            self.active -= 1;
        }
    }

    /// Free every open trace's arena. Call before the model goes away so no
    /// arena outlives the app; opening more afterward is fine.
    pub fn deinitAll(self: *Model) void {
        var i: usize = 0;
        while (i < self.trace_count) : (i += 1) self.traces[i].deinit(self.backing);
        self.trace_count = 0;
        self.active = 0;
    }
};

/// The built-in sample trace: the vendored normal-session fixture, embedded so
/// the empty state has a one-click demo and the smoke test always has content.
/// `@embedFile` resolves within the `src/` module root, so `../ocpp/...` stays
/// in-tree.
pub const sample_name = "normal-session (sample)";
pub const sample_bytes = @embedFile("../ocpp/testdata/normal-session.json");

pub fn update(model: *Model, msg: Msg) void {
    switch (msg) {
        .open_sample => model.openBytes(sample_name, sample_bytes),
        .select_trace => |i| model.selectTrace(i),
        .close_trace => |i| model.closeTrace(i),
    }
}

/// Run the whole engine pipeline for one trace into a fresh arena. On any engine
/// error the trace is returned in its error state (arena retained so `name` and
/// the reason survive on screen); only an arena-allocation failure yields the
/// null-arena fallback.
fn loadTrace(backing: std.mem.Allocator, name: []const u8, bytes: []const u8) LoadedTrace {
    const arena_ptr = backing.create(std.heap.ArenaAllocator) catch {
        return .{ .name = "", .load_error = "out of memory" };
    };
    arena_ptr.* = std.heap.ArenaAllocator.init(backing);
    const a = arena_ptr.allocator();

    const name_copy = a.dupe(u8, name) catch {
        arena_ptr.deinit();
        backing.destroy(arena_ptr);
        return .{ .name = "", .load_error = "out of memory" };
    };

    const parsed = parser.parseTrace(a, bytes) catch |err| {
        return .{ .arena = arena_ptr, .name = name_copy, .load_error = @errorName(err) };
    };
    const sessions = timeline.buildSessionTimeline(a, parsed.events) catch |err| {
        return .{ .arena = arena_ptr, .name = name_copy, .events = parsed.events, .warnings = parsed.warnings, .load_error = @errorName(err) };
    };
    const failures = detection.detectFailures(a, parsed.events, sessions) catch |err| {
        return .{ .arena = arena_ptr, .name = name_copy, .events = parsed.events, .sessions = sessions, .warnings = parsed.warnings, .load_error = @errorName(err) };
    };

    return .{
        .arena = arena_ptr,
        .name = name_copy,
        .events = parsed.events,
        .sessions = sessions,
        .failures = failures,
        .warnings = parsed.warnings,
    };
}

/// Build an error-state trace holding just `name` and `reason` in a small arena
/// (for failures that happen before parsing, like a missing file).
fn errorTrace(backing: std.mem.Allocator, name: []const u8, reason: []const u8) LoadedTrace {
    const arena_ptr = backing.create(std.heap.ArenaAllocator) catch {
        return .{ .name = "", .load_error = "out of memory" };
    };
    arena_ptr.* = std.heap.ArenaAllocator.init(backing);
    const a = arena_ptr.allocator();
    const name_copy = a.dupe(u8, name) catch "";
    const reason_copy = a.dupe(u8, reason) catch "load failed";
    return .{ .arena = arena_ptr, .name = name_copy, .load_error = reason_copy };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "empty workspace has no active trace" {
    var model = Model{ .backing = testing.allocator };
    defer model.deinitAll();
    try testing.expect(!model.hasTraces());
    try testing.expectEqual(@as(?*const LoadedTrace, null), model.activeTrace());
}

test "opening the sample loads events, sessions, and correlates" {
    var model = Model{ .backing = testing.allocator };
    defer model.deinitAll();

    update(&model, .open_sample);

    try testing.expect(model.hasTraces());
    try testing.expectEqual(@as(usize, 1), model.trace_count);
    const t = model.activeTrace().?;
    try testing.expect(!t.isError());
    try testing.expectEqualStrings(sample_name, t.name);
    // The vendored fixture is 22 events correlating into one completed session.
    try testing.expectEqual(@as(usize, 22), t.eventCount());
    try testing.expectEqual(@as(usize, 1), t.sessionCount());
    try testing.expectEqual(types.Status.completed, t.sessions[0].status);
}

test "select and close manage the active index and free arenas" {
    var model = Model{ .backing = testing.allocator };
    defer model.deinitAll();

    update(&model, .open_sample);
    update(&model, .open_sample);
    update(&model, .open_sample);
    try testing.expectEqual(@as(usize, 3), model.trace_count);
    try testing.expectEqual(@as(usize, 2), model.active); // newest is active

    update(&model, .{ .select_trace = 0 });
    try testing.expectEqual(@as(usize, 0), model.active);

    // Closing the active (0) keeps a valid active and compacts the list.
    update(&model, .{ .close_trace = 0 });
    try testing.expectEqual(@as(usize, 2), model.trace_count);
    try testing.expect(model.active < model.trace_count);

    // Closing out to empty resets cleanly (and leaks nothing — testing.allocator).
    update(&model, .{ .close_trace = 0 });
    update(&model, .{ .close_trace = 0 });
    try testing.expect(!model.hasTraces());
}

test "closing a trace before the active one keeps the same trace active" {
    var model = Model{ .backing = testing.allocator };
    defer model.deinitAll();
    update(&model, .open_sample);
    update(&model, .open_sample);
    update(&model, .open_sample);
    update(&model, .{ .select_trace = 2 });
    update(&model, .{ .close_trace = 0 });
    // Was index 2 of 3; one earlier tab closed → now index 1 of 2.
    try testing.expectEqual(@as(usize, 2), model.trace_count);
    try testing.expectEqual(@as(usize, 1), model.active);
}

test "a malformed trace opens in its error state without crashing" {
    var model = Model{ .backing = testing.allocator };
    defer model.deinitAll();

    model.openBytes("broken.json", "this is not a trace");

    try testing.expect(model.hasTraces());
    const t = model.activeTrace().?;
    try testing.expect(t.isError());
    try testing.expectEqualStrings("broken.json", t.name);
    try testing.expectEqual(@as(usize, 0), t.eventCount());
}

test "the workspace is bounded at max_open_traces" {
    var model = Model{ .backing = testing.allocator };
    defer model.deinitAll();
    var i: usize = 0;
    while (i < max_open_traces + 3) : (i += 1) update(&model, .open_sample);
    try testing.expectEqual(max_open_traces, model.trace_count);
}
