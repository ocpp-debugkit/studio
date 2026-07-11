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

/// The first `row` widget whose subtree contains `text` — used to grab a
/// pressable timeline row by the message it shows.
fn findRowWithText(widget: canvas.Widget, text: []const u8) ?canvas.Widget {
    if (widget.kind == .row and findByText(widget, .text, text) != null) return widget;
    for (widget.children) |child| {
        if (findRowWithText(child, text)) |found| return found;
    }
    return null;
}

fn countRole(widget: canvas.Widget, role: canvas.WidgetRole) usize {
    var n: usize = if (widget.semantics.role == role) 1 else 0;
    for (widget.children) |child| n += countRole(child, role);
    return n;
}

/// The first `text` widget whose content starts with `prefix` — the raw JSON
/// view is one text node holding the whole pretty-printed array.
fn findTextPrefix(widget: canvas.Widget, prefix: []const u8) ?canvas.Widget {
    if (widget.kind == .text and std.mem.startsWith(u8, widget.text, prefix)) return widget;
    for (widget.children) |child| {
        if (findTextPrefix(child, prefix)) |found| return found;
    }
    return null;
}

/// The first `treeitem` row whose own label text equals `key` — used to grab a
/// payload-tree row (flat rows, so a row's subtree holds only its own texts).
fn findTreeItem(widget: canvas.Widget, key: []const u8) ?canvas.Widget {
    if (widget.semantics.role == .treeitem and findByText(widget, .text, key) != null) return widget;
    for (widget.children) |child| {
        if (findTreeItem(child, key)) |found| return found;
    }
    return null;
}

/// A single-Call trace whose MeterValues payload exercises every tree shape:
/// scalars, a nested object, an array, an over-deep chain, and an over-wide
/// array. `wide` holds 50 elements (past the breadth bound of 40); `deep`
/// nests 6 levels (past the depth bound). Caller owns nothing — `openBytes`
/// copies it.
fn nestedTraceBytes(a: std.mem.Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{\"events\":[{\"message\":[2,\"m1\",\"MeterValues\",{" ++
        "\"connectorId\":1," ++
        "\"meterValue\":[{\"timestamp\":\"2024-01-01T00:00:00Z\",\"sampledValue\":[{\"value\":\"42.5\",\"unit\":\"Wh\"}]}]," ++
        "\"deep\":{\"a\":{\"b\":{\"c\":{\"d\":{\"e\":{\"f\":\"tooDeep\"}}}}}}," ++
        "\"wide\":[");
    for (0..50) |i| {
        if (i > 0) try buf.appendSlice(a, ",");
        try buf.append(a, '0' + @as(u8, @intCast(i % 10)));
    }
    try buf.appendSlice(a, "]}]}]}");
    return buf.items;
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

test "clicking Open sample loads the sample and the timeline renders it" {
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

    // Rebuild: the timeline renders event rows (the first is a BootNotification
    // Call) and the status bar summarizes the trace.
    tree = try buildTree(arena, &model);
    _ = try expectByText(tree.root, .text, "BootNotification");
    const status = findKind(tree.root, .status_bar) orelse return error.WidgetNotFound;
    try testing.expect(std.mem.indexOf(u8, status.text, "22 events") != null);
}

test "clicking a timeline row selects the event and the detail pane reflects it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{ .backing = testing.allocator };
    defer model.deinitAll();
    workspace.update(&model, .open_sample);

    var tree = try buildTree(arena, &model);
    _ = try expectByText(tree.root, .text, "Select an event to inspect it");

    // Press the BootNotification row (event 0); selection follows through the
    // pressable row's on_press.
    const row = findRowWithText(tree.root, "BootNotification") orelse return error.WidgetNotFound;
    main.update(&model, tree.msgForPointer(row.id, .up).?);
    try testing.expectEqual(@as(?usize, 0), model.activeTrace().?.selected_event);

    // Rebuild: the detail pane shows the selected event's fields.
    tree = try buildTree(arena, &model);
    _ = try expectByText(tree.root, .text, "evt-0001"); // the event id
    _ = try expectByText(tree.root, .text, "Message ID"); // a detail-row label
}

test "selecting an event renders every message-inspector section" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{ .backing = testing.allocator };
    defer model.deinitAll();
    workspace.update(&model, .open_sample);
    workspace.update(&model, .{ .select_event = 0 });

    const tree = try buildTree(arena, &model);
    _ = try expectByText(tree.root, .text, "Details");
    _ = try expectByText(tree.root, .text, "Session");
    _ = try expectByText(tree.root, .text, "Payload");
    _ = try expectByText(tree.root, .text, "Raw message");
    _ = try expectByText(tree.root, .button, "Jump to first event");
    // The raw view pretty-prints the OCPP-J array into one text node opening
    // with the array bracket on its own line.
    const raw = findTextPrefix(tree.root, "[\n") orelse return error.WidgetNotFound;
    try testing.expect(std.mem.indexOf(u8, raw.text, "BootNotification") != null);
    // The payload renders as a disclosure tree with at least one treeitem row.
    try testing.expect(countRole(tree.root, .treeitem) > 0);
}

test "the session panel reflects the event's session and jumps to the first event" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{ .backing = testing.allocator };
    defer model.deinitAll();
    workspace.update(&model, .open_sample);
    // Select a mid-session event (the StopTransaction Call, well past event 0).
    workspace.update(&model, .{ .select_event = 12 });

    var tree = try buildTree(arena, &model);
    // The sample's one session carries transactionId 100001 and completed.
    _ = try expectByText(tree.root, .text, "100001");
    _ = try expectByText(tree.root, .text, "completed");

    // Jump-to-first-event selects the session's first event (the BootNotification).
    const jump = try expectByText(tree.root, .button, "Jump to first event");
    main.update(&model, tree.msgForPointer(jump.id, .up).?);
    try testing.expectEqual(@as(?usize, 0), model.activeTrace().?.selected_event);

    tree = try buildTree(arena, &model);
    _ = try expectByText(tree.root, .text, "evt-0001");
}

test "the payload tree renders object, array, and scalar shapes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{ .backing = testing.allocator };
    defer model.deinitAll();
    model.openBytes("nested.json", try nestedTraceBytes(arena));
    workspace.update(&model, .{ .select_event = 0 });

    const tree = try buildTree(arena, &model);
    // Object field (scalar), a nested array, and an array-index row.
    _ = try expectByText(tree.root, .text, "connectorId");
    _ = try expectByText(tree.root, .text, "meterValue");
    _ = try expectByText(tree.root, .text, "sampledValue");
    // A scalar string leaf renders quoted; a number renders bare.
    _ = try expectByText(tree.root, .text, "\"Wh\"");
    _ = try expectByText(tree.root, .text, "1"); // connectorId's value
}

test "the payload tree bounds depth and breadth" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{ .backing = testing.allocator };
    defer model.deinitAll();
    model.openBytes("nested.json", try nestedTraceBytes(arena));
    workspace.update(&model, .{ .select_event = 0 });

    const tree = try buildTree(arena, &model);
    // The over-deep chain stops before its leaf: "tooDeep" never renders.
    try testing.expect(findByText(tree.root, .text, "\"tooDeep\"") == null);
    // The over-wide array shows a truncation marker instead of all 50 elements.
    try testing.expect(findByText(tree.root, .text, "... 10 more") != null);
    // The whole tree stays within the tracked node budget.
    try testing.expect(countRole(tree.root, .treeitem) <= workspace.max_payload_tree_nodes);
}

test "toggling a payload container collapses its children" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{ .backing = testing.allocator };
    defer model.deinitAll();
    model.openBytes("nested.json", try nestedTraceBytes(arena));
    workspace.update(&model, .{ .select_event = 0 });

    var tree = try buildTree(arena, &model);
    // "timestamp" lives under meterValue → visible while expanded.
    _ = try expectByText(tree.root, .text, "timestamp");
    const mv = findTreeItem(tree.root, "meterValue") orelse return error.WidgetNotFound;

    // Collapse meterValue through its row's on_press.
    main.update(&model, tree.msgForPointer(mv.id, .up).?);
    tree = try buildTree(arena, &model);
    // meterValue itself stays; its descendant "timestamp" is gone.
    _ = try expectByText(tree.root, .text, "meterValue");
    try testing.expect(findByText(tree.root, .text, "timestamp") == null);
}

test "the failure panel shows the clean-trace positive state" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = Model{ .backing = testing.allocator };
    defer model.deinitAll();
    workspace.update(&model, .open_sample); // the sample is a clean session

    const tree = try buildTree(arena_state.allocator(), &model);
    _ = try expectByText(tree.root, .text, "Failures"); // the drawer header
    _ = try expectByText(tree.root, .text, "No failures detected");
}

test "the failure panel lists failures, expands steps, and jumps to the event" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{ .backing = testing.allocator };
    defer model.deinitAll();
    // The failed-auth conformance fixture detects one FAILED_AUTHORIZATION.
    model.openBytes("failed-auth.json", @embedFile("ocpp/conformance/fixtures/failed-auth.json"));

    var tree = try buildTree(arena, &model);
    _ = try expectByText(tree.root, .text, "FAILED_AUTHORIZATION");
    // Collapsed: remediation is hidden until the row is opened.
    try testing.expect(findByText(tree.root, .text, "Suggested steps") == null);

    // Clicking the failure row expands it and jumps to its primary event.
    const row = findRowWithText(tree.root, "FAILED_AUTHORIZATION") orelse return error.WidgetNotFound;
    main.update(&model, tree.msgForPointer(row.id, .up).?);
    try testing.expectEqual(@as(?usize, 0), model.activeTrace().?.expanded_failure);
    try testing.expect(model.activeTrace().?.selected_event != null);

    tree = try buildTree(arena, &model);
    _ = try expectByText(tree.root, .text, "Suggested steps");
    _ = try expectByText(tree.root, .text, "Affected");
}

test "the virtual window stays viewport-sized at dataset scale" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    // Half a million events, but the window derives from the viewport, not the
    // count: the timeline materializes only a few dozen row nodes — far under
    // the 1024-node per-view budget. This is the capacity claim in miniature
    // (the engine side lands in #29).
    var ui = Ui.init(arena_state.allocator());
    const window = ui.virtualWindow(.{
        .id = "event-timeline",
        .item_count = 500_000,
        .item_extent = 44,
        .overscan = 6,
        .viewport_fallback = 640,
    });
    try testing.expect(window.itemCount() > 0);
    try testing.expect(window.itemCount() < 64);
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

    workspace.update(&model, .{ .select_event = 5 }); // detail pane: tree, session, raw
    tree = try buildTree(arena, &model);
    try canvas.expectA11yAuditSweepClean(testing.allocator, tree.root, sweep);

    // A trace with an expanded failure exercises the failure drawer too.
    var failing = Model{ .backing = testing.allocator };
    defer failing.deinitAll();
    failing.openBytes("failed-auth.json", @embedFile("ocpp/conformance/fixtures/failed-auth.json"));
    workspace.update(&failing, .{ .select_failure = 0 });
    tree = try buildTree(arena, &failing);
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
