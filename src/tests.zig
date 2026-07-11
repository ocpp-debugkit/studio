//! Headless integration tests for the inspector view: build the real
//! `canvas.Ui` tree from `inspector.view`, assert on its widgets, and drive the
//! model through the same typed dispatch path the runtime uses — no GUI needed.
//! Workspace-model unit tests live beside the code in `ui/workspace.zig`.

const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");
const workspace = @import("ui/workspace.zig");
const inspector = @import("ui/inspector.zig");

const canvas = native_sdk.canvas;
const testing = std.testing;

const Ui = inspector.Ui;
const Model = main.Model;
const Msg = main.Msg;

fn buildTree(arena: std.mem.Allocator, model: *const Model) !Ui.Tree {
    var ui = Ui.init(arena);
    return ui.finalize(inspector.view(&ui, model));
}

fn findByText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) ?canvas.Widget {
    if (widget.kind == kind and std.mem.eql(u8, widget.text, text)) return widget;
    for (widget.children) |child| {
        if (findByText(child, kind, text)) |found| return found;
    }
    return null;
}

fn expectByText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) !canvas.Widget {
    return findByText(widget, kind, text) orelse {
        std.debug.print("no {t} with text \"{s}\" in the inspector view\n", .{ kind, text });
        return error.WidgetNotFound;
    };
}

fn findKind(widget: canvas.Widget, kind: canvas.WidgetKind) ?canvas.Widget {
    if (widget.kind == kind) return widget;
    for (widget.children) |child| {
        if (findKind(child, kind)) |found| return found;
    }
    return null;
}

test "the empty workspace offers the open-sample affordance" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = Model{ .backing = testing.allocator };
    defer model.deinitAll();

    const tree = try buildTree(arena_state.allocator(), &model);
    _ = try expectByText(tree.root, .text, "No trace open");
    _ = try expectByText(tree.root, .button, "Open sample");
}

test "clicking Open sample loads the sample and the overview reflects it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{ .backing = testing.allocator };
    defer model.deinitAll();

    // Press "Open sample" through the real dispatch path.
    var tree = try buildTree(arena, &model);
    const open = try expectByText(tree.root, .button, "Open sample");
    main.update(&model, tree.msgForPointer(open.id, .up).?);
    try testing.expect(model.hasTraces());

    // Rebuild: the overview shows the event count and the status bar summarizes.
    tree = try buildTree(arena, &model);
    _ = try expectByText(tree.root, .text, "22"); // events stat tile value
    _ = try expectByText(tree.root, .text, "events");
    const status = findKind(tree.root, .status_bar) orelse return error.WidgetNotFound;
    try testing.expect(std.mem.indexOf(u8, status.text, "22 events") != null);
}

test "a second trace produces a tab strip that switches the active trace" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{ .backing = testing.allocator };
    defer model.deinitAll();
    workspace.update(&model, .open_sample);
    workspace.update(&model, .open_sample);
    try testing.expectEqual(@as(usize, 1), model.active); // newest active

    // Two tabs render as buttons carrying the trace name; clicking the first
    // switches the active trace.
    const tree = try buildTree(arena, &model);
    const first_tab = try expectByText(tree.root, .button, workspace.sample_name);
    main.update(&model, tree.msgForPointer(first_tab.id, .up).?);
    try testing.expectEqual(@as(usize, 0), model.active);
}

test "an unreadable trace opens in the error state without crashing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = Model{ .backing = testing.allocator };
    defer model.deinitAll();
    model.openLoadError("missing.json", "FileNotFound");

    const tree = try buildTree(arena_state.allocator(), &model);
    _ = try expectByText(tree.root, .text, "Could not read this trace");
    _ = try expectByText(tree.root, .text, "FileNotFound");
}

test "the inspector view passes the accessibility sweep (empty and loaded)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const sweep = canvas.a11y.A11yAuditSweepOptions{
        .min_size = .{ .width = 900, .height = 560 },
        .default_size = .{ .width = 1200, .height = 800 },
    };

    var model = Model{ .backing = testing.allocator };
    defer model.deinitAll();

    var tree = try buildTree(arena, &model); // empty state
    try canvas.expectA11yAuditSweepClean(testing.allocator, tree.root, sweep);

    workspace.update(&model, .open_sample); // loaded state
    tree = try buildTree(arena, &model);
    try canvas.expectA11yAuditSweepClean(testing.allocator, tree.root, sweep);
}

test "the inspector view lays out through the canvas engine" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = Model{ .backing = testing.allocator };
    defer model.deinitAll();
    workspace.update(&model, .open_sample);

    const tree = try buildTree(arena_state.allocator(), &model);
    var nodes: [256]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(tree.root, native_sdk.geometry.RectF.init(0, 0, 1200, 800), &nodes);
    try testing.expect(layout.nodes.len > 0);
}
