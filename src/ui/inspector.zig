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
    return ui.column(.{ .grow = 1 }, .{
        topBar(ui, model),
        ui.separator(.{}),
        activeBody(ui, model),
        statusBar(ui, model),
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

fn activeBody(ui: *Ui, model: *const Model) Node {
    const t = model.activeTrace().?;
    if (t.isError()) return errorPanel(ui, t);
    // Timeline (left) / detail (right), a model-owned splitter that echoes each
    // drag back through `timeline_split`.
    return ui.split(.{
        .grow = 1,
        .value = model.timeline_split,
        .on_resize = Ui.valueMsg(.timeline_resized),
    }, .{
        timelinePane(ui, t),
        detailPane(ui, t),
    });
}

fn errorPanel(ui: *Ui, t: *const LoadedTrace) Node {
    return ui.column(.{ .grow = 1, .main = .center, .cross = .center, .gap = 8, .padding = 24 }, .{
        ui.text(.{ .size = .heading }, "Could not read this trace"),
        ui.text(.{}, t.load_error orelse "unknown error"),
    });
}

// --- timeline pane: the windowed virtual list ------------------------------

fn timelinePane(ui: *Ui, t: *const LoadedTrace) Node {
    const opts = Ui.VirtualListOptions{
        .id = "event-timeline",
        .item_count = t.events.len,
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
        const index = window.start_index + offset;
        var node = eventRow(ui, t, index);
        node.key = .{ .int = @intCast(index) }; // identity = the event, not the slot
        row.* = node;
    }
    return ui.column(.{ .min_width = 360, .grow = 1 }, .{
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

// --- detail pane: minimal for now; #30 enriches it -------------------------

fn detailPane(ui: *Ui, t: *const LoadedTrace) Node {
    if (t.selected_event) |idx| {
        if (idx < t.events.len) return eventDetail(ui, t.events[idx]);
    }
    return ui.column(.{ .min_width = 280, .grow = 1, .main = .center, .cross = .center, .padding = 24 }, .{
        ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, "Select an event to inspect it"),
    });
}

fn eventDetail(ui: *Ui, e: types.Event) Node {
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
    return ui.column(.{ .min_width = 280, .grow = 1, .gap = 10, .padding = 16 }, .{
        ui.text(.{ .size = .heading }, e.action orelse e.message_type.toWire()),
        ui.column(.{ .gap = 6 }, rows[0..n]),
    });
}

fn detailRow(ui: *Ui, label: []const u8, value: []const u8) Node {
    return ui.row(.{ .gap = 8, .cross = .start }, .{
        ui.text(.{ .width = 96, .style_tokens = .{ .foreground = .text_muted } }, label),
        ui.text(.{ .grow = 1 }, value),
    });
}

// --- status bar ------------------------------------------------------------

fn statusBar(ui: *Ui, model: *const Model) Node {
    const t = model.activeTrace().?;
    const text = if (t.isError())
        std.fmt.allocPrint(ui.arena, "Failed to load {s}: {s}", .{ t.name, t.load_error orelse "unknown error" }) catch "load failed"
    else
        std.fmt.allocPrint(ui.arena, "{d} events \u{00B7} {d} sessions \u{00B7} {d} failures \u{00B7} {d} warnings", .{
            t.eventCount(), t.sessionCount(), t.failureCount(), t.warningCount(),
        }) catch "";
    return ui.statusBar(.{}, text);
}
