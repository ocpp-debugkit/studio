//! The inspector view — a hand-written `canvas.Ui` builder view, not `.native`
//! markup (ADR-0006): the event timeline needs the windowed virtual list, which
//! is builder-only. This module owns the visual half of the TEA loop; all state
//! and transitions live in `workspace.zig`.
//!
//! S3 shell scope: the empty state, the workspace tab strip, a per-trace
//! overview (counts), the error state, and the status bar. The virtualized
//! timeline and the detail panes replace `activeBody` in the issues that follow.

const std = @import("std");
const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;
const workspace = @import("workspace.zig");
const ocpp = @import("../ocpp/ocpp.zig");
const types = ocpp.types;

const Model = workspace.Model;
const Msg = workspace.Msg;
const LoadedTrace = workspace.LoadedTrace;

pub const Ui = canvas.Ui(Msg);
const Node = Ui.Node;

/// Fixed timeline row height (points). Uniform rows are the virtual list's fast
/// path: the visible window is pure arithmetic, so a 500k-event trace still
/// materializes only ~viewport/extent row nodes.
const row_extent: f32 = 44;

pub fn view(ui: *Ui, model: *const Model) Node {
    if (!model.hasTraces()) return emptyState(ui);
    const t = model.activeTrace().?;
    if (t.isError()) {
        return ui.column(.{ .grow = 1 }, .{
            topBar(ui, model),
            ui.separator(.{}),
            errorPanel(ui, t),
            statusBar(ui, model, null),
        });
    }
    // Derive the filtered index set ONCE (in the build arena) and thread it to
    // the timeline and the status bar. Null = no active filter: the timeline
    // indexes `t.events` directly, so an unfiltered huge trace allocates nothing.
    const filtered: ?[]const usize =
        if (model.filter.isActive()) filteredIndices(ui, t, &model.filter) else null;
    return ui.column(.{ .grow = 1 }, .{
        topBar(ui, model),
        ui.separator(.{}),
        filterBar(ui, model),
        ui.separator(.{}),
        activeBody(ui, model, filtered),
        statusBar(ui, model, filtered),
    });
}

// --- empty state -----------------------------------------------------------

fn emptyState(ui: *Ui) Node {
    return ui.column(.{ .grow = 1, .main = .center, .cross = .center, .gap = 10, .padding = 24 }, .{
        ui.text(.{ .size = .heading }, "No trace open"),
        ui.text(.{}, "Open the built-in sample, or pass a trace file on the command line:"),
        ui.text(.{}, "studio path/to/trace.json"),
        ui.button(.{ .on_press = .open_sample, .variant = .primary }, "Open sample"),
    });
}

// --- top bar: tabs / single-trace name + close -----------------------------

fn topBar(ui: *Ui, model: *const Model) Node {
    const tabs = model.open();
    const left: Node = if (tabs.len > 1) tabStrip(ui, model) else ui.text(.{ .grow = 1 }, tabs[0].name);
    return ui.row(.{ .gap = 8, .cross = .center, .padding = 8 }, .{
        left,
        ui.spacer(1),
        ui.button(.{ .on_press = .{ .close_trace = model.active }, .variant = .ghost, .size = .sm }, "Close"),
    });
}

fn tabStrip(ui: *Ui, model: *const Model) Node {
    const tabs = model.open();
    const nodes = ui.arena.alloc(Node, tabs.len) catch {
        ui.failed = true;
        return ui.row(.{}, .{});
    };
    for (tabs, 0..) |*t, i| {
        nodes[i] = ui.button(.{
            .on_press = .{ .select_trace = i },
            .selected = (i == model.active),
            .variant = if (i == model.active) .secondary else .ghost,
            .size = .sm,
        }, t.name);
    }
    return ui.row(.{ .gap = 4, .cross = .center, .grow = 1 }, nodes);
}

// --- active trace body: overview or error ----------------------------------

fn activeBody(ui: *Ui, model: *const Model, filtered: ?[]const usize) Node {
    const t = model.activeTrace().?;
    // Timeline (left) / detail (right) fill the space above a fixed-height
    // failure drawer. `split` is horizontal-only, so the vertical stack is a
    // column: the split grows, the drawer keeps its height.
    return ui.column(.{ .grow = 1 }, .{
        ui.split(.{
            .grow = 1,
            .value = model.timeline_split,
            .on_resize = Ui.valueMsg(.timeline_resized),
        }, .{
            timelinePane(ui, t, filtered),
            detailPane(ui, t),
        }),
        ui.separator(.{}),
        failuresPanel(ui, t),
    });
}

fn errorPanel(ui: *Ui, t: *const LoadedTrace) Node {
    return ui.column(.{ .grow = 1, .main = .center, .cross = .center, .gap = 8, .padding = 24 }, .{
        ui.text(.{ .size = .heading }, "Could not read this trace"),
        ui.text(.{}, t.load_error orelse "unknown error"),
    });
}

// --- filter bar (#32) ------------------------------------------------------
//
// A full-width toolbar over the timeline: a free-text search field plus toggle
// facets (message type, direction, severity) that AND-compose. The derived
// filtered index set (below) drives the virtual list, so hidden rows are never
// materialized.

fn filterBar(ui: *Ui, model: *const Model) Node {
    const f = &model.filter;
    return ui.row(.{ .padding = 8, .gap = 6, .cross = .center }, .{
        ui.el(.search_field, .{
            .grow = 1,
            .min_width = 160,
            .text = f.searchText(),
            .placeholder = "Search action, id, or payload",
            .on_input = Ui.inputMsg(.search_input),
            .semantics = .{ .label = "search events" },
        }, .{}),
        facetButton(ui, "Call", .{ .toggle_type_filter = .call }, f.message_type == .call),
        facetButton(ui, "Result", .{ .toggle_type_filter = .call_result }, f.message_type == .call_result),
        facetButton(ui, "Error", .{ .toggle_type_filter = .call_error }, f.message_type == .call_error),
        ui.separator(.{}),
        facetButton(ui, "From CP", .{ .toggle_direction_filter = .cs_to_csms }, f.direction == .cs_to_csms),
        facetButton(ui, "From CSMS", .{ .toggle_direction_filter = .csms_to_cs }, f.direction == .csms_to_cs),
        ui.separator(.{}),
        facetButton(ui, "Crit", .{ .toggle_severity_filter = .critical }, f.severity == .critical),
        facetButton(ui, "Warn", .{ .toggle_severity_filter = .warning }, f.severity == .warning),
        facetButton(ui, "Info", .{ .toggle_severity_filter = .info }, f.severity == .info),
        clearFilterButton(ui, f),
    });
}

fn facetButton(ui: *Ui, label: []const u8, msg: Msg, active: bool) Node {
    return ui.button(.{
        .on_press = msg,
        .selected = active,
        .variant = if (active) .secondary else .ghost,
        .size = .sm,
    }, label);
}

fn clearFilterButton(ui: *Ui, f: *const workspace.Filter) Node {
    if (!f.isActive()) return ui.spacer(0);
    return ui.button(.{ .on_press = .clear_filters, .variant = .ghost, .size = .sm }, "Clear");
}

// --- filter predicate + filtered index derive ------------------------------

/// The matching event indices, in timeline order, allocated in the build arena.
/// Called only when the filter is active (see `view`).
fn filteredIndices(ui: *Ui, t: *const LoadedTrace, f: *const workspace.Filter) []const usize {
    var list: std.ArrayList(usize) = .empty;
    const needle = f.searchText();
    for (t.events, 0..) |e, i| {
        if (matchesFilter(t, e, f, needle)) {
            list.append(ui.arena, i) catch {
                ui.failed = true;
                break;
            };
        }
    }
    return list.items;
}

fn matchesFilter(t: *const LoadedTrace, e: types.Event, f: *const workspace.Filter, needle: []const u8) bool {
    if (f.direction) |d| if (e.direction != d) return false;
    if (f.message_type) |mt| if (e.message_type != mt) return false;
    if (f.severity) |sev| if (!participatesInSeverity(t, e.id, sev)) return false;
    if (needle.len > 0) if (!matchesText(e, needle)) return false;
    return true;
}

/// True when `event_id` participates in any detected failure of severity `sev`.
fn participatesInSeverity(t: *const LoadedTrace, event_id: []const u8, sev: types.FailureSeverity) bool {
    for (t.failures) |failure| {
        if (failure.severity != sev) continue;
        for (failure.event_ids) |eid| {
            if (std.mem.eql(u8, eid, event_id)) return true;
        }
    }
    return false;
}

/// Case-insensitive free-text match over the event's action, unique id, error
/// fields, and payload (bounded scan of string keys/values).
fn matchesText(e: types.Event, needle: []const u8) bool {
    if (e.action) |a| if (containsCI(a, needle)) return true;
    if (containsCI(e.message_id, needle)) return true;
    if (e.error_code) |c| if (containsCI(c, needle)) return true;
    if (e.error_description) |d| if (containsCI(d, needle)) return true;
    return payloadContainsText(e.payload, needle, 0);
}

fn containsCI(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

fn payloadContainsText(value: std.json.Value, needle: []const u8, depth: usize) bool {
    if (depth > 4) return false;
    switch (value) {
        .string => |s| return containsCI(s, needle),
        .number_string => |s| return containsCI(s, needle),
        .array => |a| {
            for (a.items, 0..) |item, i| {
                if (i >= 32) break;
                if (payloadContainsText(item, needle, depth + 1)) return true;
            }
            return false;
        },
        .object => |o| {
            const keys = o.keys();
            const vals = o.values();
            for (keys, 0..) |k, i| {
                if (i >= 32) break;
                if (containsCI(k, needle)) return true;
                if (payloadContainsText(vals[i], needle, depth + 1)) return true;
            }
            return false;
        },
        else => return false,
    }
}

// --- timeline pane: the windowed virtual list ------------------------------

/// `filtered` null = show all events (display index == event index); non-null =
/// the filtered event indices, so only matching rows exist and hidden rows never
/// become widgets (the window stays viewport-sized either way).
// --- replay transport (#44): manual step / scrub over the (filtered) timeline ---
//
// A step control that walks the current selection through the visible events —
// first / prev / next / last — reusing `select_event` with view-computed target
// indices, so stepping and clicking share one selection model. The current event
// is highlighted in the timeline exactly as a click would. Real wall-clock
// auto-play needs a timer source the zero-config runner does not expose, so it is
// deferred to the runner-eject bucket (#33).

const TransportTargets = struct {
    first: ?usize = null,
    prev: ?usize = null,
    next: ?usize = null,
    last: ?usize = null,
};

/// Real event index for display position `d` under the (optional) filter.
fn realIndexAt(filtered: ?[]const usize, d: usize) usize {
    return if (filtered) |fi| fi[d] else d;
}

/// Display position of the current selection within the visible set, or null
/// when nothing is selected or the selection is hidden by the active filter.
fn transportPosition(t: *const LoadedTrace, filtered: ?[]const usize, count: usize) ?usize {
    const sel = t.selected_event orelse return null;
    if (filtered) |fi| {
        for (fi, 0..) |real, d| if (real == sel) return d;
        return null;
    }
    return if (sel < count) sel else null;
}

/// Target real-indices for the four step controls. All null when there are no
/// visible events. Boundaries clamp (prev at the start / next at the end stay
/// put); with no current position, prev → last and next → first.
fn transportTargets(filtered: ?[]const usize, count: usize, cur: ?usize) TransportTargets {
    if (count == 0) return .{};
    const first = realIndexAt(filtered, 0);
    const last = realIndexAt(filtered, count - 1);
    const prev = if (cur) |c| realIndexAt(filtered, if (c > 0) c - 1 else 0) else last;
    const next = if (cur) |c| realIndexAt(filtered, if (c + 1 < count) c + 1 else count - 1) else first;
    return .{ .first = first, .prev = prev, .next = next, .last = last };
}

fn replayTransport(ui: *Ui, t: *const LoadedTrace, filtered: ?[]const usize) Node {
    const count = if (filtered) |fi| fi.len else t.events.len;
    const cur = transportPosition(t, filtered, count);
    const targets = transportTargets(filtered, count, cur);
    const muted = canvas.StyleTokenRefs{ .foreground = .text_muted };
    const pos: []const u8 = if (cur) |c|
        (std.fmt.allocPrint(ui.arena, "{d} / {d}", .{ c + 1, count }) catch "…")
    else
        (std.fmt.allocPrint(ui.arena, "- / {d}", .{count}) catch "…");
    return ui.row(.{ .padding = 6, .gap = 4, .cross = .center }, .{
        ui.text(.{ .style_tokens = muted }, "Replay"),
        transportButton(ui, "First", targets.first),
        transportButton(ui, "Prev", targets.prev),
        transportButton(ui, "Next", targets.next),
        transportButton(ui, "Last", targets.last),
        ui.spacer(1),
        ui.text(.{ .style_tokens = muted }, pos),
    });
}

fn transportButton(ui: *Ui, label: []const u8, target: ?usize) Node {
    return ui.button(.{
        .on_press = if (target) |ti| Msg{ .select_event = ti } else null,
        .variant = .ghost,
        .size = .sm,
    }, label);
}

fn timelinePane(ui: *Ui, t: *const LoadedTrace, filtered: ?[]const usize) Node {
    const count = if (filtered) |fi| fi.len else t.events.len;
    if (filtered != null and count == 0) {
        return ui.column(.{ .min_width = 360, .grow = 1 }, .{
            replayTransport(ui, t, filtered),
            ui.separator(.{}),
            timelineHeader(ui),
            ui.separator(.{}),
            centeredNote(ui, "No matching events"),
        });
    }
    const opts = Ui.VirtualListOptions{
        .id = "event-timeline",
        .item_count = count,
        .item_extent = row_extent,
        .overscan = 6,
        .grow = 1,
        // Used only by bare `finalize` builds (tests); under UiApp the runtime
        // window source uses the pane's real height instead.
        .viewport_fallback = 640,
        .semantics = .{ .label = "event timeline" },
    };
    const window = ui.virtualWindow(opts);
    const rows = ui.arena.alloc(Node, window.itemCount()) catch {
        ui.failed = true;
        return ui.column(.{ .min_width = 360, .grow = 1 }, .{});
    };
    for (rows, 0..) |*row, offset| {
        const display = window.start_index + offset;
        const index = if (filtered) |fi| fi[display] else display;
        var node = eventRow(ui, t, index);
        node.key = .{ .int = @intCast(index) }; // identity = the event, not the slot
        row.* = node;
    }
    return ui.column(.{ .min_width = 360, .grow = 1 }, .{
        replayTransport(ui, t, filtered),
        ui.separator(.{}),
        timelineHeader(ui),
        ui.separator(.{}),
        ui.virtualList(opts, window, .{rows}),
    });
}

fn timelineHeader(ui: *Ui) Node {
    const muted = canvas.StyleTokenRefs{ .foreground = .text_muted };
    return ui.row(.{ .padding = 6, .gap = 8, .cross = .center }, .{
        ui.text(.{ .width = 16 }, ""),
        ui.text(.{ .width = 44, .style_tokens = muted }, "#"),
        ui.text(.{ .width = 100, .style_tokens = muted }, "Time"),
        ui.text(.{ .width = 24 }, ""),
        ui.text(.{ .grow = 1, .style_tokens = muted }, "Message"),
        ui.text(.{ .width = 88, .style_tokens = muted }, "Type"),
    });
}

fn eventRow(ui: *Ui, t: *const LoadedTrace, index: usize) Node {
    const e = t.events[index];
    const number = std.fmt.allocPrint(ui.arena, "{d}", .{index + 1}) catch "";
    return ui.row(.{
        .on_press = .{ .select_event = index },
        .selected = (t.selected_event == index),
        .height = row_extent,
        .padding = 6,
        .gap = 8,
        .cross = .center,
    }, .{
        severityDot(ui, eventSeverity(t, e.id)),
        ui.text(.{ .width = 44, .style_tokens = .{ .foreground = .text_muted } }, number),
        ui.text(.{ .width = 100 }, formatTime(ui.arena, e.timestamp)),
        directionIcon(ui, e.direction),
        ui.text(.{ .grow = 1 }, rowSummary(ui.arena, e)),
        ui.text(.{ .width = 88, .style_tokens = .{ .foreground = .text_muted } }, e.message_type.toWire()),
    });
}

fn severityDot(ui: *Ui, severity: ?types.FailureSeverity) Node {
    const s = severity orelse return ui.text(.{ .width = 16 }, "");
    return ui.icon(.{
        .width = 16,
        .style_tokens = .{ .foreground = severityColor(s) },
        .semantics = .{ .label = severityLabel(s) },
    }, "circle-dot");
}

fn directionIcon(ui: *Ui, direction: types.Direction) Node {
    return switch (direction) {
        .cs_to_csms => ui.icon(.{ .width = 24, .semantics = .{ .label = "charge point to CSMS" } }, "chevron-right"),
        .csms_to_cs => ui.icon(.{ .width = 24, .semantics = .{ .label = "CSMS to charge point" } }, "chevron-left"),
        .unknown => ui.icon(.{ .width = 24, .semantics = .{ .label = "unknown direction" } }, "circle-dot"),
    };
}

/// The worst-severity failure the event participates in, or null. The scan is
/// over the trace's failures (few) for the built (visible) rows only.
fn eventSeverity(t: *const LoadedTrace, event_id: []const u8) ?types.FailureSeverity {
    var worst: ?types.FailureSeverity = null;
    for (t.failures) |f| {
        for (f.event_ids) |eid| {
            if (std.mem.eql(u8, eid, event_id)) {
                if (worst == null or severityRank(f.severity) < severityRank(worst.?)) worst = f.severity;
            }
        }
    }
    return worst;
}

fn severityRank(s: types.FailureSeverity) u8 {
    return switch (s) {
        .critical => 0,
        .warning => 1,
        .info => 2,
    };
}

fn severityColor(s: types.FailureSeverity) canvas.ColorTokenName {
    return switch (s) {
        .critical => .destructive,
        .warning => .warning,
        .info => .info,
    };
}

fn severityLabel(s: types.FailureSeverity) []const u8 {
    return switch (s) {
        .critical => "critical failure",
        .warning => "warning",
        .info => "info",
    };
}

fn rowSummary(arena: std.mem.Allocator, e: types.Event) []const u8 {
    return switch (e.message_type) {
        .call => e.action orelse "(call)",
        // A result's UniqueId is the call's — surfacing it lets the eye correlate.
        .call_result => e.message_id,
        .call_error => std.fmt.allocPrint(arena, "{s}: {s}", .{
            e.error_code orelse "error", e.error_description orelse "",
        }) catch (e.error_code orelse "error"),
    };
}

/// Epoch-ms → UTC time-of-day `HH:MM:SS.mmm`. Session timelines rarely cross a
/// day; the full date lives in the detail pane. Missing/invalid → a dash.
fn formatTime(arena: std.mem.Allocator, ts: ?i64) []const u8 {
    const ms = ts orelse return "--";
    if (ms < 0) return "--";
    const total_s = @divFloor(ms, 1000);
    return std.fmt.allocPrint(arena, "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{
        @mod(@divFloor(total_s, 3600), 24),
        @mod(@divFloor(total_s, 60), 60),
        @mod(total_s, 60),
        @mod(ms, 1000),
    }) catch "--";
}

// --- detail pane: message inspector + session panel (#30) ------------------
//
// The selected event, fully unpacked: its normalized fields, the session it
// correlates into (with a jump-to-first-event control), a disclosure tree over
// the payload, and the raw OCPP-J array pretty-printed. The whole pane scrolls.

/// Payload-tree display bounds (the id space is `workspace.max_payload_tree_nodes`).
/// Depth/breadth keep a hostile payload from ballooning the widget-node budget;
/// past them the tree shows a compact "... N more" / "... truncated" marker.
const max_payload_tree_depth: usize = 6;
const max_payload_tree_breadth: usize = 40;
/// Per-row indentation (points) for the flat disclosure tree.
const tree_indent: f32 = 14;
/// Cap on the pretty-printed raw JSON so one event can't produce a giant text
/// layout; payloads are small, this only bites pathological input.
const max_raw_bytes: usize = 8 * 1024;

fn detailPane(ui: *Ui, t: *const LoadedTrace) Node {
    const idx = t.selected_event orelse return detailPlaceholder(ui);
    if (idx >= t.events.len) return detailPlaceholder(ui);
    return ui.scroll(.{ .min_width = 300, .grow = 1 }, .{
        ui.column(.{ .gap = 14, .padding = 16 }, .{
            eventDetail(ui, t, idx),
        }),
    });
}

fn detailPlaceholder(ui: *Ui) Node {
    return ui.column(.{ .min_width = 300, .grow = 1, .main = .center, .cross = .center, .padding = 24 }, .{
        ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, "Select an event to inspect it"),
    });
}

fn eventDetail(ui: *Ui, t: *const LoadedTrace, idx: usize) Node {
    const e = t.events[idx];
    return ui.column(.{ .gap = 14 }, .{
        ui.text(.{ .size = .heading }, e.action orelse e.message_type.toWire()),
        normalizedSection(ui, e),
        sessionSection(ui, t, e.id),
        payloadSection(ui, t, e),
        rawSection(ui, e),
    });
}

/// A titled, separated block. Every detail section shares this frame.
fn section(ui: *Ui, title: []const u8, body: Node) Node {
    return ui.column(.{ .gap = 6 }, .{
        ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, title),
        ui.separator(.{}),
        body,
    });
}

// --- normalized fields -----------------------------------------------------

fn normalizedSection(ui: *Ui, e: types.Event) Node {
    var rows: [7]Node = undefined;
    var n: usize = 0;
    rows[n] = detailRow(ui, "Event", e.id);
    n += 1;
    rows[n] = detailRow(ui, "Message ID", e.message_id);
    n += 1;
    rows[n] = detailRow(ui, "Type", e.message_type.toWire());
    n += 1;
    rows[n] = detailRow(ui, "Direction", e.direction.toWire());
    n += 1;
    rows[n] = detailRow(ui, "Time", formatTime(ui.arena, e.timestamp));
    n += 1;
    if (e.error_code) |code| {
        rows[n] = detailRow(ui, "Error code", code);
        n += 1;
    }
    if (e.error_description) |desc| {
        rows[n] = detailRow(ui, "Error", desc);
        n += 1;
    }
    return section(ui, "Details", ui.column(.{ .gap = 6 }, rows[0..n]));
}

fn detailRow(ui: *Ui, label: []const u8, value: []const u8) Node {
    return detailRowColored(ui, label, value, null);
}

fn detailRowColored(ui: *Ui, label: []const u8, value: []const u8, color: ?canvas.ColorTokenName) Node {
    const value_tokens: canvas.StyleTokenRefs = if (color) |c| .{ .foreground = c } else .{};
    return ui.row(.{ .gap = 8, .cross = .start }, .{
        ui.text(.{ .width = 96, .style_tokens = .{ .foreground = .text_muted } }, label),
        ui.text(.{ .grow = 1, .style_tokens = value_tokens }, value),
    });
}

// --- session panel ---------------------------------------------------------

fn sessionSection(ui: *Ui, t: *const LoadedTrace, event_id: []const u8) Node {
    const si = findSessionOf(t, event_id) orelse return section(
        ui,
        "Session",
        ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, "Not part of a correlated session"),
    );
    const s = t.sessions[si];

    var rows: [7]Node = undefined;
    var n: usize = 0;
    rows[n] = detailRow(ui, "Session", s.session_id);
    n += 1;
    rows[n] = detailRow(ui, "Transaction", optInt(ui.arena, s.transaction_id));
    n += 1;
    rows[n] = detailRowColored(ui, "Status", s.status.toWire(), statusColor(s.status));
    n += 1;
    rows[n] = detailRow(ui, "Connector", optInt(ui.arena, s.connector_id));
    n += 1;
    rows[n] = detailRow(ui, "Started", formatTime(ui.arena, s.start_time));
    n += 1;
    rows[n] = detailRow(ui, "Ended", formatTime(ui.arena, s.end_time));
    n += 1;
    rows[n] = detailRow(ui, "Events", std.fmt.allocPrint(ui.arena, "{d}", .{s.events.len}) catch "?");
    n += 1;

    return section(ui, "Session", ui.column(.{ .gap = 6 }, .{
        ui.column(.{ .gap = 6 }, rows[0..n]),
        ui.row(.{}, .{
            ui.button(.{ .on_press = .{ .select_session = si }, .variant = .ghost, .size = .sm }, "Jump to first event"),
        }),
    }));
}

/// The index of the session containing `event_id`, or null. Sessions hold
/// id-bearing copies of their events, so membership is an id match.
fn findSessionOf(t: *const LoadedTrace, event_id: []const u8) ?usize {
    for (t.sessions, 0..) |s, i| {
        for (s.events) |e| {
            if (std.mem.eql(u8, e.id, event_id)) return i;
        }
    }
    return null;
}

fn statusColor(s: types.Status) canvas.ColorTokenName {
    return switch (s) {
        .completed => .success,
        .aborted => .destructive,
        .active => .info,
    };
}

fn optInt(arena: std.mem.Allocator, v: ?i64) []const u8 {
    const n = v orelse return "none";
    return std.fmt.allocPrint(arena, "{d}", .{n}) catch "none";
}

// --- payload tree ----------------------------------------------------------

/// Flat-list disclosure tree over a JSON payload. Rows are emitted in pre-order;
/// a collapsed container simply omits its descendants' rows. Node ids are the
/// pre-order rank over the *bounded* structure and are independent of collapse
/// state (the walk always advances the id counter over every in-bounds node,
/// whether or not it emits a row), so a collapse bit always names the same node
/// across rebuilds.
const TreeWalk = struct {
    ui: *Ui,
    collapsed: *const workspace.PayloadCollapse,
    list: *std.ArrayList(Node),
    /// Next pre-order id to hand out.
    id: usize = 0,
    /// Set once the id space (`workspace.max_payload_tree_nodes`) is exhausted.
    truncated: bool = false,
};

fn payloadSection(ui: *Ui, t: *const LoadedTrace, e: types.Event) Node {
    switch (e.payload) {
        .null => return section(ui, "Payload", emptyNote(ui, "No payload")),
        .object => |o| if (o.count() == 0) return section(ui, "Payload", emptyNote(ui, "Empty object {}")),
        .array => |a| if (a.items.len == 0) return section(ui, "Payload", emptyNote(ui, "Empty array []")),
        else => {},
    }

    var list: std.ArrayList(Node) = .empty;
    var w = TreeWalk{ .ui = ui, .collapsed = &t.payload_collapsed, .list = &list };
    if (isContainer(e.payload)) {
        // Expose the payload's fields directly (no synthetic "payload" root row).
        walkChildren(&w, e.payload, 0, true);
    } else {
        walkPayload(&w, "value", e.payload, 0, true);
    }
    if (w.truncated) {
        list.append(ui.arena, moreRow(ui, "... payload truncated", 0)) catch {
            ui.failed = true;
        };
    }
    return section(ui, "Payload", ui.tree(.{ .semantics = .{ .label = "payload" } }, list.items));
}

fn emptyNote(ui: *Ui, text: []const u8) Node {
    return ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, text);
}

/// Emit (and id-count) one JSON value as a tree row plus, when it is an expanded
/// container, its children. `visible` is false inside a collapsed ancestor — the
/// subtree still consumes ids so identities stay stable, but no rows are added.
fn walkPayload(w: *TreeWalk, key: []const u8, value: std.json.Value, depth: usize, visible: bool) void {
    if (w.id >= workspace.max_payload_tree_nodes) {
        w.truncated = true;
        return;
    }
    const id = w.id;
    w.id += 1;

    const child_count = jsonLen(value);
    const expandable = isContainer(value) and child_count > 0 and depth + 1 < max_payload_tree_depth;
    const expanded = expandable and !w.collapsed.isSet(id);

    if (visible) {
        w.list.append(w.ui.arena, treeRow(w.ui, key, value, depth, id, expandable, expanded, child_count)) catch {
            w.ui.failed = true;
        };
    }

    if (!isContainer(value) or child_count == 0 or depth + 1 >= max_payload_tree_depth) return;
    walkChildren(w, value, depth + 1, visible and expanded);
}

/// Walk a container's children at `depth`, bounded by breadth. `child_visible`
/// gates emission; ids advance regardless.
fn walkChildren(w: *TreeWalk, value: std.json.Value, depth: usize, child_visible: bool) void {
    const total = jsonLen(value);
    const shown = @min(total, max_payload_tree_breadth);
    switch (value) {
        .array => |a| {
            var i: usize = 0;
            while (i < shown) : (i += 1) {
                const label = std.fmt.allocPrint(w.ui.arena, "{d}", .{i}) catch "?";
                walkPayload(w, label, a.items[i], depth, child_visible);
            }
        },
        .object => |o| {
            const keys = o.keys();
            const vals = o.values();
            var i: usize = 0;
            while (i < shown) : (i += 1) {
                walkPayload(w, keys[i], vals[i], depth, child_visible);
            }
        },
        else => {},
    }
    if (child_visible and total > shown) {
        const label = std.fmt.allocPrint(w.ui.arena, "... {d} more", .{total - shown}) catch "... more";
        w.list.append(w.ui.arena, moreRow(w.ui, label, depth)) catch {
            w.ui.failed = true;
        };
    }
}

fn treeRow(ui: *Ui, key: []const u8, value: std.json.Value, depth: usize, id: usize, expandable: bool, expanded: bool, child_count: usize) Node {
    const indent: f32 = @as(f32, @floatFromInt(depth)) * tree_indent;
    return ui.row(.{
        .semantics = .{ .role = .treeitem, .label = key },
        .expanded = if (expandable) expanded else null,
        .on_press = if (expandable) Msg{ .toggle_payload_node = id } else null,
        .on_toggle = if (expandable) Msg{ .toggle_payload_node = id } else null,
        .padding = 3,
        .gap = 6,
        .cross = .center,
    }, .{
        ui.text(.{ .width = indent }, ""),
        disclosureGlyph(ui, expandable, expanded),
        ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, key),
        ui.text(.{ .grow = 1 }, valueSummary(ui.arena, value, child_count)),
    });
}

/// The leading disclosure slot: a chevron for expandable rows (the icon name is
/// comptime, so the two states are separate calls), a blank spacer for leaves.
fn disclosureGlyph(ui: *Ui, expandable: bool, expanded: bool) Node {
    if (!expandable) return ui.text(.{ .width = 16 }, "");
    if (expanded) return ui.icon(.{
        .width = 16,
        .style_tokens = .{ .foreground = .text_muted },
        .semantics = .{ .label = "collapse" },
    }, "chevron-down");
    return ui.icon(.{
        .width = 16,
        .style_tokens = .{ .foreground = .text_muted },
        .semantics = .{ .label = "expand" },
    }, "chevron-right");
}

/// A non-interactive marker row (breadth/depth truncation), aligned to the key
/// column at `depth`.
fn moreRow(ui: *Ui, text: []const u8, depth: usize) Node {
    const indent: f32 = @as(f32, @floatFromInt(depth)) * tree_indent + 16;
    return ui.row(.{ .padding = 3, .gap = 6, .cross = .center }, .{
        ui.text(.{ .width = indent }, ""),
        ui.text(.{ .grow = 1, .style_tokens = .{ .foreground = .text_muted } }, text),
    });
}

fn isContainer(value: std.json.Value) bool {
    return value == .array or value == .object;
}

fn jsonLen(value: std.json.Value) usize {
    return switch (value) {
        .array => |a| a.items.len,
        .object => |o| o.count(),
        else => 0,
    };
}

/// The compact right-hand summary of a tree row: a size for containers, the
/// scalar itself for leaves.
fn valueSummary(arena: std.mem.Allocator, value: std.json.Value, child_count: usize) []const u8 {
    return switch (value) {
        .object => if (child_count == 0) "{}" else std.fmt.allocPrint(arena, "{{ {d} }}", .{child_count}) catch "{ ... }",
        .array => if (child_count == 0) "[]" else std.fmt.allocPrint(arena, "[ {d} ]", .{child_count}) catch "[ ... ]",
        else => jsonScalar(arena, value),
    };
}

/// A scalar JSON value rendered for display: strings quoted, everything else as
/// written. Long strings are cut at a UTF-8 boundary so nothing renders as tofu.
fn jsonScalar(arena: std.mem.Allocator, value: std.json.Value) []const u8 {
    return switch (value) {
        .null => "null",
        .bool => |b| if (b) "true" else "false",
        .integer => |n| std.fmt.allocPrint(arena, "{d}", .{n}) catch "?",
        .float => |f| std.fmt.allocPrint(arena, "{d}", .{f}) catch "?",
        .number_string => |s| truncateDisplay(arena, s, 96),
        .string => |s| std.fmt.allocPrint(arena, "\"{s}\"", .{truncateDisplay(arena, s, 96)}) catch "\"...\"",
        else => "",
    };
}

fn truncateDisplay(arena: std.mem.Allocator, s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var cut = max;
    // Back off any UTF-8 continuation bytes so we never split a codepoint.
    while (cut > 0 and (s[cut] & 0xC0) == 0x80) cut -= 1;
    return std.fmt.allocPrint(arena, "{s}...", .{s[0..cut]}) catch s[0..cut];
}

// --- raw OCPP-J array ------------------------------------------------------

fn rawSection(ui: *Ui, e: types.Event) Node {
    var buf: std.ArrayList(u8) = .empty;
    writeJson(ui.arena, &buf, e.raw_message, 0);
    if (buf.items.len >= max_raw_bytes) {
        buf.appendSlice(ui.arena, "\n... (truncated)") catch {};
    }
    return section(ui, "Raw message", ui.text(.{ .grow = 1 }, buf.items));
}

/// Minimal pretty-printer over `std.json.Value` → 2-space-indented JSON. Bounded
/// by `max_raw_bytes`; used for the raw view only (never for engine output), so
/// display-faithful escaping is all it owes.
fn writeJson(a: std.mem.Allocator, buf: *std.ArrayList(u8), value: std.json.Value, depth: usize) void {
    if (buf.items.len >= max_raw_bytes) return;
    switch (value) {
        .null => append(a, buf, "null"),
        .bool => |b| append(a, buf, if (b) "true" else "false"),
        .integer => |n| {
            var tmp: [24]u8 = undefined;
            append(a, buf, std.fmt.bufPrint(&tmp, "{d}", .{n}) catch "0");
        },
        .float => |f| {
            var tmp: [32]u8 = undefined;
            append(a, buf, std.fmt.bufPrint(&tmp, "{d}", .{f}) catch "0");
        },
        .number_string => |s| append(a, buf, s),
        .string => |s| writeJsonString(a, buf, s),
        .array => |arr| {
            if (arr.items.len == 0) return append(a, buf, "[]");
            append(a, buf, "[\n");
            for (arr.items, 0..) |item, i| {
                if (buf.items.len >= max_raw_bytes) break;
                writeIndent(a, buf, depth + 1);
                writeJson(a, buf, item, depth + 1);
                if (i + 1 < arr.items.len) append(a, buf, ",");
                append(a, buf, "\n");
            }
            writeIndent(a, buf, depth);
            append(a, buf, "]");
        },
        .object => |obj| {
            if (obj.count() == 0) return append(a, buf, "{}");
            append(a, buf, "{\n");
            const keys = obj.keys();
            const vals = obj.values();
            for (keys, vals, 0..) |k, v, i| {
                if (buf.items.len >= max_raw_bytes) break;
                writeIndent(a, buf, depth + 1);
                writeJsonString(a, buf, k);
                append(a, buf, ": ");
                writeJson(a, buf, v, depth + 1);
                if (i + 1 < keys.len) append(a, buf, ",");
                append(a, buf, "\n");
            }
            writeIndent(a, buf, depth);
            append(a, buf, "}");
        },
    }
}

fn writeJsonString(a: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) void {
    append(a, buf, "\"");
    for (s) |c| switch (c) {
        '"' => append(a, buf, "\\\""),
        '\\' => append(a, buf, "\\\\"),
        '\n' => append(a, buf, "\\n"),
        '\r' => append(a, buf, "\\r"),
        '\t' => append(a, buf, "\\t"),
        else => {
            if (c < 0x20) {
                var tmp: [8]u8 = undefined;
                append(a, buf, std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch "");
            } else {
                buf.append(a, c) catch {};
            }
        },
    };
    append(a, buf, "\"");
}

fn writeIndent(a: std.mem.Allocator, buf: *std.ArrayList(u8), depth: usize) void {
    var i: usize = 0;
    while (i < depth) : (i += 1) append(a, buf, "  ");
}

fn append(a: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) void {
    buf.appendSlice(a, s) catch {};
}

// --- failure panel (#31) ---------------------------------------------------
//
// Every detected failure for the active trace, ranked critical -> warning ->
// info (then by first event), in a fixed-height drawer beneath the timeline.
// Selecting a failure expands its remediation steps (accordion, at most one
// open) and jumps to its primary event so the failure and its evidence align.

const failures_panel_height: f32 = 240;
const max_failures_shown: usize = 50;

fn failuresPanel(ui: *Ui, t: *const LoadedTrace) Node {
    return ui.column(.{ .height = failures_panel_height }, .{
        failuresHeader(ui, t),
        ui.separator(.{}),
        failuresBody(ui, t),
    });
}

fn failuresHeader(ui: *Ui, t: *const LoadedTrace) Node {
    return ui.row(.{ .padding = 8, .gap = 8, .cross = .center }, .{
        ui.text(.{}, "Failures"),
        ui.spacer(1),
        ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, failuresSummary(ui.arena, t.failures)),
    });
}

fn failuresBody(ui: *Ui, t: *const LoadedTrace) Node {
    if (t.detection_skipped)
        return centeredNote(ui, "Failure detection was skipped for this large trace");
    if (t.failures.len == 0)
        return centeredNote(ui, "No failures detected");

    const order = sortedFailureIndices(ui.arena, t.failures);
    const shown = @min(order.len, max_failures_shown);
    const extra: usize = if (order.len > shown) 1 else 0;
    const rows = ui.arena.alloc(Node, shown + extra) catch {
        ui.failed = true;
        return centeredNote(ui, "");
    };
    for (0..shown) |k| rows[k] = failureRow(ui, t, order[k]);
    if (extra == 1) {
        const label = std.fmt.allocPrint(ui.arena, "... {d} more", .{order.len - shown}) catch "... more";
        rows[shown] = moreRow(ui, label, 0);
    }
    return ui.scroll(.{ .grow = 1 }, .{
        ui.column(.{ .gap = 4, .padding = 8 }, rows),
    });
}

fn centeredNote(ui: *Ui, text: []const u8) Node {
    return ui.column(.{ .grow = 1, .main = .center, .cross = .center, .padding = 16 }, .{
        ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, text),
    });
}

fn failureRow(ui: *Ui, t: *const LoadedTrace, i: usize) Node {
    const f = t.failures[i];
    const expanded = (t.expanded_failure == i);
    const header = ui.row(.{
        .on_press = .{ .select_failure = i },
        .selected = expanded,
        .padding = 6,
        .gap = 8,
        .cross = .center,
        .semantics = .{ .label = f.code.toWire() },
    }, .{
        severityDot(ui, f.severity),
        ui.text(.{ .style_tokens = .{ .foreground = severityColor(f.severity) } }, f.code.toWire()),
        ui.text(.{ .grow = 1 }, f.description),
        disclosureGlyph(ui, true, expanded),
    });
    if (!expanded) return header;
    return ui.column(.{ .gap = 4 }, .{
        header,
        failureDetail(ui, f),
    });
}

fn failureDetail(ui: *Ui, f: types.Failure) Node {
    var items: std.ArrayList(Node) = .empty;
    items.append(ui.arena, detailRow(ui, "Affected", joinEventIds(ui.arena, f.event_ids))) catch {
        ui.failed = true;
    };
    if (f.suggested_steps.len > 0) {
        items.append(ui.arena, ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, "Suggested steps")) catch {};
        for (f.suggested_steps) |step| {
            items.append(ui.arena, stepRow(ui, step)) catch {};
        }
    }
    return ui.column(.{ .gap = 4, .padding = 8 }, items.items);
}

fn stepRow(ui: *Ui, step: []const u8) Node {
    return ui.row(.{ .gap = 6, .cross = .start }, .{
        ui.text(.{ .width = 16, .style_tokens = .{ .foreground = .text_muted } }, "\u{00B7}"),
        ui.text(.{ .grow = 1 }, step),
    });
}

/// Affected event ids as a compact comma-joined list, capped so a many-event
/// failure stays readable.
fn joinEventIds(arena: std.mem.Allocator, ids: []const []const u8) []const u8 {
    if (ids.len == 0) return "none";
    const cap: usize = 6;
    const shown = @min(ids.len, cap);
    var buf: std.ArrayList(u8) = .empty;
    for (ids[0..shown], 0..) |id, i| {
        if (i > 0) buf.appendSlice(arena, ", ") catch {};
        buf.appendSlice(arena, id) catch {};
    }
    if (ids.len > shown) {
        buf.appendSlice(arena, std.fmt.allocPrint(arena, ", +{d} more", .{ids.len - shown}) catch "") catch {};
    }
    return buf.items;
}

/// Display order for the failure list: severity (critical -> warning -> info),
/// then first affected event id. Returns indices into `failures`; the engine's
/// slice is never mutated.
fn sortedFailureIndices(arena: std.mem.Allocator, failures: []const types.Failure) []usize {
    const idx = arena.alloc(usize, failures.len) catch return &.{};
    for (idx, 0..) |*v, i| v.* = i;
    std.mem.sort(usize, idx, failures, lessFailure);
    return idx;
}

fn lessFailure(failures: []const types.Failure, a: usize, b: usize) bool {
    const fa = failures[a];
    const fb = failures[b];
    const ra = severityRank(fa.severity);
    const rb = severityRank(fb.severity);
    if (ra != rb) return ra < rb;
    const ea = if (fa.event_ids.len > 0) fa.event_ids[0] else "";
    const eb = if (fb.event_ids.len > 0) fb.event_ids[0] else "";
    return std.mem.order(u8, ea, eb) == .lt;
}

/// "N failures: C critical, W warning, I info" (nonzero severities only), or
/// "no failures". Shared by the failure-panel header and the status bar.
fn failuresSummary(arena: std.mem.Allocator, failures: []const types.Failure) []const u8 {
    if (failures.len == 0) return "no failures";
    var counts = [_]usize{ 0, 0, 0 }; // critical, warning, info
    for (failures) |f| counts[severityRank(f.severity)] += 1;

    var buf: std.ArrayList(u8) = .empty;
    buf.appendSlice(arena, std.fmt.allocPrint(arena, "{d} failure{s}", .{ failures.len, if (failures.len == 1) "" else "s" }) catch "") catch {};
    var first = true;
    for ([_][]const u8{ "critical", "warning", "info" }, 0..) |word, rank| {
        if (counts[rank] > 0) {
            const sep = if (first) ": " else ", ";
            buf.appendSlice(arena, std.fmt.allocPrint(arena, "{s}{d} {s}", .{ sep, counts[rank], word }) catch "") catch {};
            first = false;
        }
    }
    return buf.items;
}

// --- status bar ------------------------------------------------------------

fn statusBar(ui: *Ui, model: *const Model, filtered: ?[]const usize) Node {
    const t = model.activeTrace().?;
    if (t.isError()) {
        const msg = std.fmt.allocPrint(ui.arena, "Failed to load {s}: {s}", .{ t.name, t.load_error orelse "unknown error" }) catch "load failed";
        return ui.statusBar(.{}, msg);
    }
    // When a filter is active the count reflects matches out of the whole trace.
    const events_seg = if (filtered) |fi|
        std.fmt.allocPrint(ui.arena, "{d} of {d} events", .{ fi.len, t.eventCount() }) catch ""
    else
        std.fmt.allocPrint(ui.arena, "{d} events", .{t.eventCount()}) catch "";
    const text = if (t.detection_skipped)
        std.fmt.allocPrint(ui.arena, "{s} \u{00B7} {d} sessions \u{00B7} detection skipped (large trace) \u{00B7} {d} parse warnings", .{
            events_seg, t.sessionCount(), t.warningCount(),
        }) catch ""
    else
        std.fmt.allocPrint(ui.arena, "{s} \u{00B7} {d} sessions \u{00B7} {s} \u{00B7} {d} parse warnings", .{
            events_seg, t.sessionCount(), failuresSummary(ui.arena, t.failures), t.warningCount(),
        }) catch "";
    return ui.statusBar(.{}, text);
}

// ---------------------------------------------------------------------------
// Tests — pure view helpers (widget-level behavior is covered in tests.zig)
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testFailure(code: types.FailureCode, severity: types.FailureSeverity, comptime first_event: []const u8) types.Failure {
    return .{
        .code = code,
        .description = "test",
        .severity = severity,
        // `first_event` is comptime so `&.{first_event}` is a static array, not
        // a dangling pointer into this frame.
        .event_ids = &.{first_event},
        .suggested_steps = &.{},
    };
}

test "failures sort critical -> warning -> info, then by first event" {
    const failures = [_]types.Failure{
        testFailure(.slow_response, .warning, "evt-0005"),
        testFailure(.connector_fault, .critical, "evt-0009"),
        testFailure(.heartbeat_interval_violation, .info, "evt-0002"),
        testFailure(.failed_authorization, .warning, "evt-0003"),
        testFailure(.station_offline_during_session, .critical, "evt-0001"),
    };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const order = sortedFailureIndices(arena_state.allocator(), &failures);
    // critical (evt-0001, evt-0009), then warning (evt-0003, evt-0005), then info.
    try testing.expectEqualSlices(usize, &.{ 4, 1, 3, 0, 2 }, order);
}

test "failuresSummary breaks down nonzero severities" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try testing.expectEqualStrings("no failures", failuresSummary(a, &.{}));

    const failures = [_]types.Failure{
        testFailure(.connector_fault, .critical, "evt-0001"),
        testFailure(.slow_response, .warning, "evt-0002"),
        testFailure(.failed_authorization, .warning, "evt-0003"),
    };
    try testing.expectEqualStrings("3 failures: 1 critical, 2 warning", failuresSummary(a, &failures));

    const one = [_]types.Failure{testFailure(.heartbeat_interval_violation, .info, "evt-0001")};
    try testing.expectEqualStrings("1 failure: 1 info", failuresSummary(a, &one));
}

test "matchesText searches action, id, and payload case-insensitively" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const payload = std.json.parseFromSliceLeaky(
        std.json.Value,
        a,
        "{\"idTag\":\"ABC123\",\"nested\":{\"reason\":\"Local\"}}",
        .{},
    ) catch unreachable;
    const e = types.Event{
        .id = "evt-0001",
        .message_id = "msg-77",
        .timestamp = null,
        .direction = .cs_to_csms,
        .message_type = .call,
        .action = "Authorize",
        .payload = payload,
        .error_code = null,
        .error_description = null,
        .raw_message = .null,
    };

    try testing.expect(matchesText(e, "auth")); // action, case-insensitive
    try testing.expect(matchesText(e, "MSG-77")); // unique id, case-insensitive
    try testing.expect(matchesText(e, "abc123")); // payload string value
    try testing.expect(matchesText(e, "idTag")); // payload key
    try testing.expect(matchesText(e, "local")); // nested value, case-insensitive
    try testing.expect(!matchesText(e, "zzz"));
}
