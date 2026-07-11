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

const Model = workspace.Model;
const Msg = workspace.Msg;
const LoadedTrace = workspace.LoadedTrace;

pub const Ui = canvas.Ui(Msg);
const Node = Ui.Node;

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
    return overview(ui, t);
}

fn errorPanel(ui: *Ui, t: *const LoadedTrace) Node {
    return ui.column(.{ .grow = 1, .main = .center, .cross = .center, .gap = 8, .padding = 24 }, .{
        ui.text(.{ .size = .heading }, "Could not read this trace"),
        ui.text(.{}, t.load_error orelse "unknown error"),
    });
}

fn overview(ui: *Ui, t: *const LoadedTrace) Node {
    return ui.column(.{ .grow = 1, .gap = 16, .padding = 24 }, .{
        ui.text(.{ .size = .heading }, t.name),
        ui.row(.{ .gap = 12, .cross = .start }, .{
            statTile(ui, t.eventCount(), "events"),
            statTile(ui, t.sessionCount(), "sessions"),
            statTile(ui, t.failureCount(), "failures"),
            statTile(ui, t.warningCount(), "warnings"),
        }),
        ui.text(.{}, "The event timeline and inspector panes arrive in the next step."),
    });
}

fn statTile(ui: *Ui, value: usize, label: []const u8) Node {
    const value_str = std.fmt.allocPrint(ui.arena, "{d}", .{value}) catch "?";
    return ui.column(.{ .gap = 2, .padding = 12, .min_width = 92 }, .{
        ui.text(.{ .size = .heading }, value_str),
        ui.text(.{}, label),
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
