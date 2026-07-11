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
const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;
const ocpp = @import("../ocpp/ocpp.zig");
const parser = ocpp.parser;
const timeline = ocpp.timeline;
const detection = ocpp.detection;
const types = ocpp.types;

/// Upper bound on simultaneously open traces (workspace tabs). A hard cap keeps
/// the tab strip and per-trace arenas bounded; opening past it is a no-op.
pub const max_open_traces: usize = 8;

/// Upper bound on payload-tree node identities the inspector tracks for the
/// selected event. Node ids are pre-order ranks over the (depth/breadth-bounded)
/// payload the view walks; capping the id space keeps collapse state a
/// fixed-size bitset and stops a pathological payload from growing the tree past
/// the view's widget-node budget. `inspector.zig` enforces the same bound when
/// it walks the payload, so ids stay in [0, max_payload_tree_nodes).
pub const max_payload_tree_nodes: usize = 100;

/// Collapse state for the selected event's payload tree: bit `id` set = node
/// `id` is collapsed. All-clear (the default) = every container expanded. A
/// plain value type, so it copies with the trace during tab compaction and
/// resets to empty when the trace is freed.
pub const PayloadCollapse = std.StaticBitSet(max_payload_tree_nodes);

/// Max length of the timeline free-text search query.
pub const max_search_len: usize = 128;

/// Timeline search + filter state. Facets AND-compose; an inactive filter shows
/// the whole timeline. Lives on the `Model` (never memcpy'd) and stores the
/// search query as a fixed buffer + length + caret — no stored slice pointer —
/// so the struct stays trivially copyable and self-reference-free.
pub const Filter = struct {
    search_buf: [max_search_len]u8 = undefined,
    search_len: usize = 0,
    search_sel: canvas.TextSelection = .{},
    /// Facets (null = any).
    direction: ?types.Direction = null,
    message_type: ?types.MessageType = null,
    /// Match events that participate in a failure of this severity.
    severity: ?types.FailureSeverity = null,

    pub fn searchText(self: *const Filter) []const u8 {
        return self.search_buf[0..self.search_len];
    }

    pub fn isActive(self: *const Filter) bool {
        return self.search_len > 0 or self.direction != null or
            self.message_type != null or self.severity != null;
    }

    /// A `TextEditState` view over the current query (slice computed fresh).
    pub fn editState(self: *const Filter) canvas.TextEditState {
        return .{ .text = self.searchText(), .selection = self.search_sel };
    }
};

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
    /// True when failure detection was skipped because the trace exceeds
    /// `detection.max_events_for_detection` (ADR-0007). The trace is still fully
    /// parsed, correlated, and inspectable; `failures` is empty.
    detection_skipped: bool = false,
    /// The timeline row the user selected, if any (wired in the timeline PR).
    selected_event: ?usize = null,
    /// Collapse state for the selected event's payload tree (`PayloadCollapse`).
    /// Reset whenever `selected_event` changes, so each event's tree opens
    /// fully expanded.
    payload_collapsed: PayloadCollapse = PayloadCollapse.initEmpty(),
    /// The failure whose remediation steps are expanded in the failure panel
    /// (an accordion — at most one open), as an index into `failures`.
    expanded_failure: ?usize = null,

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
    /// Select event `payload` (a timeline row) in the active trace.
    select_event: usize,
    /// Toggle collapse of payload-tree node `payload` for the active trace's
    /// selected event.
    toggle_payload_node: usize,
    /// Jump to session `payload` in the active trace by selecting its first
    /// event (drives the detail and session panels to that session).
    select_session: usize,
    /// Toggle failure `payload`'s remediation steps in the failure panel and
    /// jump to its primary event.
    select_failure: usize,
    /// The timeline / detail splitter moved to fraction `payload`.
    timeline_resized: f32,
    /// A text edit (`insert`, `delete`, `clear`, …) from the search field.
    search_input: canvas.TextInputEvent,
    /// Toggle the direction facet to `payload` (or off, if already set to it).
    toggle_direction_filter: types.Direction,
    /// Toggle the message-type facet to `payload` (or off).
    toggle_type_filter: types.MessageType,
    /// Toggle the severity facet to `payload` (or off).
    toggle_severity_filter: types.FailureSeverity,
    /// Reset every facet and the search query.
    clear_filters,
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
    /// The timeline / detail splitter fraction (first pane), model-owned so the
    /// `split` reconcile echoes it back through `value` after each drag.
    timeline_split: f32 = 0.62,
    /// Search + filter applied to the active trace's timeline. Model-owned (not
    /// per-trace) so the query buffer keeps a stable address.
    filter: Filter = .{},

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

    /// Select a timeline row (event index) in the active trace. Out-of-range
    /// indices are ignored. Changing the selection resets the payload-tree
    /// collapse state, so the newly selected event opens fully expanded.
    pub fn selectEvent(self: *Model, index: usize) void {
        if (self.trace_count == 0) return;
        const t = &self.traces[self.active];
        if (index >= t.events.len) return;
        if (t.selected_event != index) t.payload_collapsed = PayloadCollapse.initEmpty();
        t.selected_event = index;
    }

    /// Toggle the collapsed state of payload-tree node `id` for the active
    /// trace's selected event. Ids at or past the tracked range are ignored.
    pub fn togglePayloadNode(self: *Model, id: usize) void {
        if (self.trace_count == 0) return;
        if (id >= max_payload_tree_nodes) return;
        self.traces[self.active].payload_collapsed.toggle(id);
    }

    /// Jump to session `index` in the active trace by selecting its first
    /// event. Sessions hold id-bearing copies of their events (timeline.zig),
    /// so the first event maps back to a timeline row by its stable event id.
    /// Out-of-range indices and empty sessions are ignored.
    pub fn selectSession(self: *Model, index: usize) void {
        if (self.trace_count == 0) return;
        const t = &self.traces[self.active];
        if (index >= t.sessions.len) return;
        const s = t.sessions[index];
        if (s.events.len == 0) return;
        self.selectEventById(s.events[0].id);
    }

    /// Toggle failure `index`'s expansion in the failure panel (accordion: at
    /// most one open) and jump to its primary event. A second activation of the
    /// open failure just collapses it, leaving the selection put. Out-of-range
    /// indices are ignored.
    pub fn selectFailure(self: *Model, index: usize) void {
        if (self.trace_count == 0) return;
        const t = &self.traces[self.active];
        if (index >= t.failures.len) return;
        if (t.expanded_failure == index) {
            t.expanded_failure = null;
            return;
        }
        t.expanded_failure = index;
        const f = t.failures[index];
        if (f.event_ids.len > 0) self.selectEventById(f.event_ids[0]);
    }

    /// Select the timeline row whose event id equals `id`, if present.
    fn selectEventById(self: *Model, id: []const u8) void {
        const t = &self.traces[self.active];
        for (t.events, 0..) |e, i| {
            if (std.mem.eql(u8, e.id, id)) {
                self.selectEvent(i);
                return;
            }
        }
    }

    /// Apply a search-field text edit to the query buffer. The edit is applied
    /// into a scratch buffer (no aliasing with the persistent one), then copied
    /// back and re-pointed. An edit that would overflow the query is dropped.
    pub fn applySearchInput(self: *Model, ev: canvas.TextInputEvent) void {
        var scratch: [max_search_len]u8 = undefined;
        const next = canvas.applyTextInputEvent(self.filter.editState(), ev, &scratch) catch return;
        const n = @min(next.text.len, self.filter.search_buf.len);
        @memcpy(self.filter.search_buf[0..n], next.text[0..n]);
        self.filter.search_len = n;
        self.filter.search_sel = .{
            .anchor = @min(next.selection.anchor, n),
            .focus = @min(next.selection.focus, n),
        };
    }

    /// Reset every facet and the search query to the inactive state.
    pub fn clearFilters(self: *Model) void {
        self.filter = .{};
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
        .select_event => |i| model.selectEvent(i),
        .toggle_payload_node => |id| model.togglePayloadNode(id),
        .select_session => |i| model.selectSession(i),
        .select_failure => |i| model.selectFailure(i),
        .timeline_resized => |f| model.timeline_split = f,
        .search_input => |ev| model.applySearchInput(ev),
        .toggle_direction_filter => |d| model.filter.direction = if (model.filter.direction == d) null else d,
        .toggle_type_filter => |t| model.filter.message_type = if (model.filter.message_type == t) null else t,
        .toggle_severity_filter => |s| model.filter.severity = if (model.filter.severity == s) null else s,
        .clear_filters => model.clearFilters(),
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

    // Files reach the workspace because the user opened them (command line, and
    // later a dialog / drag-drop), so they parse under the trusted limits
    // (ADR-0007) — 256 MB / 2M events, far past the browser's ceiling.
    const parsed = parser.parseTraceTrusted(a, bytes) catch |err| {
        return .{ .arena = arena_ptr, .name = name_copy, .load_error = @errorName(err) };
    };
    const sessions = timeline.buildSessionTimeline(a, parsed.events) catch |err| {
        return .{ .arena = arena_ptr, .name = name_copy, .events = parsed.events, .warnings = parsed.warnings, .load_error = @errorName(err) };
    };

    // Failure detection has O(n²) rules (ADR-0007); skip it past the cap so a
    // huge trace still opens instantly and stays fully inspectable.
    if (parsed.events.len > detection.max_events_for_detection) {
        return .{
            .arena = arena_ptr,
            .name = name_copy,
            .events = parsed.events,
            .sessions = sessions,
            .warnings = parsed.warnings,
            .detection_skipped = true,
        };
    }
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

test "selecting an event records it on the active trace, bounds-checked" {
    var model = Model{ .backing = testing.allocator };
    defer model.deinitAll();
    update(&model, .open_sample);

    try testing.expectEqual(@as(?usize, null), model.activeTrace().?.selected_event);
    update(&model, .{ .select_event = 5 });
    try testing.expectEqual(@as(?usize, 5), model.activeTrace().?.selected_event);

    // Out of range is ignored (the sample has 22 events).
    update(&model, .{ .select_event = 9999 });
    try testing.expectEqual(@as(?usize, 5), model.activeTrace().?.selected_event);
}

test "toggling payload nodes flips collapse bits, bounds-checked" {
    var model = Model{ .backing = testing.allocator };
    defer model.deinitAll();
    update(&model, .open_sample);
    update(&model, .{ .select_event = 0 });

    try testing.expect(!model.activeTrace().?.payload_collapsed.isSet(3));
    update(&model, .{ .toggle_payload_node = 3 });
    try testing.expect(model.activeTrace().?.payload_collapsed.isSet(3));
    update(&model, .{ .toggle_payload_node = 3 });
    try testing.expect(!model.activeTrace().?.payload_collapsed.isSet(3));

    // Ids at/past the tracked range are ignored (no panic, no effect).
    update(&model, .{ .toggle_payload_node = max_payload_tree_nodes });
    update(&model, .{ .toggle_payload_node = 999_999 });
}

test "reselecting a different event resets payload collapse state" {
    var model = Model{ .backing = testing.allocator };
    defer model.deinitAll();
    update(&model, .open_sample);
    update(&model, .{ .select_event = 0 });
    update(&model, .{ .toggle_payload_node = 2 });
    try testing.expect(model.activeTrace().?.payload_collapsed.isSet(2));

    // A new selection opens fully expanded again.
    update(&model, .{ .select_event = 6 });
    try testing.expect(!model.activeTrace().?.payload_collapsed.isSet(2));

    // Re-selecting the same event leaves collapse state intact.
    update(&model, .{ .toggle_payload_node = 2 });
    update(&model, .{ .select_event = 6 });
    try testing.expect(model.activeTrace().?.payload_collapsed.isSet(2));
}

test "selecting a session jumps to its first event" {
    var model = Model{ .backing = testing.allocator };
    defer model.deinitAll();
    update(&model, .open_sample);
    const t = model.activeTrace().?;
    try testing.expectEqual(@as(usize, 1), t.sessionCount());

    update(&model, .{ .select_session = 0 });
    // The sample's one session begins at the BootNotification (event 0).
    const first = t.sessions[0].events[0];
    const selected = model.activeTrace().?.selected_event.?;
    try testing.expectEqualStrings(first.id, model.activeTrace().?.events[selected].id);

    // Out-of-range session index is ignored.
    update(&model, .{ .select_session = 42 });
    try testing.expectEqual(@as(?usize, selected), model.activeTrace().?.selected_event);
}

test "selecting a failure expands it and jumps to its primary event" {
    var model = Model{ .backing = testing.allocator };
    defer model.deinitAll();

    // The failed-auth conformance fixture detects one FAILED_AUTHORIZATION.
    model.openBytes("failed-auth.json", @embedFile("../ocpp/conformance/fixtures/failed-auth.json"));
    const t = model.activeTrace().?;
    try testing.expect(t.failureCount() > 0);
    try testing.expect(t.failures[0].event_ids.len > 0);
    try testing.expectEqual(@as(?usize, null), t.expanded_failure);

    update(&model, .{ .select_failure = 0 });
    const at = model.activeTrace().?;
    try testing.expectEqual(@as(?usize, 0), at.expanded_failure);
    // Jumped to (selected) the failure's primary event.
    const primary_id = at.failures[0].event_ids[0];
    const sel = at.selected_event.?;
    try testing.expectEqualStrings(primary_id, at.events[sel].id);

    // A second activation collapses the accordion; the selection stays put.
    update(&model, .{ .select_failure = 0 });
    try testing.expectEqual(@as(?usize, null), model.activeTrace().?.expanded_failure);
    try testing.expectEqual(@as(?usize, sel), model.activeTrace().?.selected_event);

    // Out-of-range failure index is ignored.
    update(&model, .{ .select_failure = 999 });
    try testing.expectEqual(@as(?usize, sel), model.activeTrace().?.selected_event);
}

test "search input builds and clears the query through edit events" {
    var model = Model{ .backing = testing.allocator };
    defer model.deinitAll();
    update(&model, .open_sample);
    try testing.expect(!model.filter.isActive());

    update(&model, .{ .search_input = .{ .insert_text = "Boot" } });
    try testing.expectEqualStrings("Boot", model.filter.searchText());
    try testing.expect(model.filter.isActive());

    update(&model, .{ .search_input = .delete_backward });
    try testing.expectEqualStrings("Boo", model.filter.searchText());

    // The search field's clear affordance (x / Escape) arrives as `.clear`.
    update(&model, .{ .search_input = .clear });
    try testing.expectEqualStrings("", model.filter.searchText());
    try testing.expect(!model.filter.isActive());
}

test "facet filters toggle on and off and clear together" {
    var model = Model{ .backing = testing.allocator };
    defer model.deinitAll();
    update(&model, .open_sample);

    update(&model, .{ .toggle_type_filter = .call });
    try testing.expectEqual(@as(?types.MessageType, .call), model.filter.message_type);
    update(&model, .{ .toggle_type_filter = .call }); // same value toggles it off
    try testing.expectEqual(@as(?types.MessageType, null), model.filter.message_type);

    update(&model, .{ .toggle_direction_filter = .cs_to_csms });
    update(&model, .{ .toggle_severity_filter = .critical });
    try testing.expect(model.filter.isActive());

    update(&model, .clear_filters);
    try testing.expect(!model.filter.isActive());
    try testing.expectEqual(@as(?types.Direction, null), model.filter.direction);
    try testing.expectEqual(@as(?types.FailureSeverity, null), model.filter.severity);
}

test "the splitter fraction is model-owned and echoed by update" {
    var model = Model{ .backing = testing.allocator };
    defer model.deinitAll();
    try testing.expectApproxEqAbs(@as(f32, 0.62), model.timeline_split, 0.0001);
    update(&model, .{ .timeline_resized = 0.4 });
    try testing.expectApproxEqAbs(@as(f32, 0.4), model.timeline_split, 0.0001);
}

test "a trace past the detection cap loads fully but skips detection" {
    var model = Model{ .backing = testing.allocator };
    defer model.deinitAll();

    // One event past the cap: it must still parse and correlate, but detection
    // is skipped (its O(n^2) rules would stall) — the trace stays inspectable.
    const count = detection.max_events_for_detection + 1;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        try buf.appendSlice(testing.allocator, "{\"message\":[2,\"m\",\"Heartbeat\",{}]}\n");
    }

    model.openBytes("big.jsonl", buf.items);
    const t = model.activeTrace().?;
    try testing.expect(!t.isError());
    try testing.expectEqual(count, t.eventCount());
    try testing.expect(t.detection_skipped);
    try testing.expectEqual(@as(usize, 0), t.failureCount());
}

test "the sample trace stays under the cap and runs detection" {
    var model = Model{ .backing = testing.allocator };
    defer model.deinitAll();
    update(&model, .open_sample);
    // 22 events, well under the cap: detection ran (and found nothing, as it's a
    // clean session).
    try testing.expect(!model.activeTrace().?.detection_skipped);
}

test "the workspace is bounded at max_open_traces" {
    var model = Model{ .backing = testing.allocator };
    defer model.deinitAll();
    var i: usize = 0;
    while (i < max_open_traces + 3) : (i += 1) update(&model, .open_sample);
    try testing.expectEqual(max_open_traces, model.trace_count);
}
