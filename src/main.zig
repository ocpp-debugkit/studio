//! OCPP DebugKit Studio — app wiring. The inspector view is a Zig `canvas.Ui`
//! builder view (ADR-0006: the event timeline needs the builder-only windowed
//! virtual list), so this file hands `UiApp` a `.view` function rather than
//! embedded `.native` markup. State and transitions live in `ui/workspace.zig`;
//! the view in `ui/inspector.zig`.
//!
//! Traces are opened from command-line path arguments — read here in `main`
//! through `init.io` (unbounded, the large-trace path #29 builds on), parsed by
//! the engine, and seeded into the workspace before the loop starts.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const workspace = @import("ui/workspace.zig");
const inspector = @import("ui/inspector.zig");
const cli = @import("cli.zig");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const geometry = native_sdk.geometry;

const canvas_label = "main-canvas";
const window_width: f32 = 1200;
const window_height: f32 = 800;
const window_min_width: f32 = 900;
const window_min_height: f32 = 560;

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view, native_sdk.security.permission_notifications };
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Studio canvas", .accessibility_label = "OCPP DebugKit Studio", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "OCPP DebugKit Studio",
    .width = window_width,
    .height = window_height,
    .min_width = window_min_width,
    .min_height = window_min_height,
    .restore_state = false,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// ------------------------------------------------------------------ TEA types

pub const Model = workspace.Model;
pub const Msg = workspace.Msg;
pub const update = workspace.update;
pub const view = inspector.view;
pub const AppUi = inspector.Ui;

// -------------------------------------------------------------------- app

const InspectorApp = native_sdk.UiApp(Model, Msg);

/// Largest trace file `main` will read from disk. Generous so the trusted
/// command-line path isn't the bottleneck; the engine parser still enforces its
/// own ingestion policy on the bytes (raised for trusted files in #29).
const max_trace_file_bytes: usize = 256 * 1024 * 1024;

/// The effects-capable update: runs the pure `workspace.update`, then issues the
/// live-capture effects — on start, spawn the capture worker (`studio capture …
/// --ndjson`), whose stdout NDJSON lines stream back as `capture_line` Msgs; on
/// stop, cancel it (ADR-0009) — and fires any OS notifications the live detector
/// queued this turn (ADR-0011).
fn updateFx(model: *Model, msg: Msg, fx: *InspectorApp.Effects) void {
    workspace.update(model, msg);
    switch (msg) {
        .start_capture => if (model.live.status == .capturing) {
            const argv = [_][]const u8{
                model.selfExe(), "capture",
                "--listen",      model.live.listen(),
                "--upstream",    model.live.upstream(),
                "--ndjson",
            };
            fx.spawn(.{
                .key = model.live.key,
                .argv = &argv,
                .output = .lines,
                .on_line = InspectorApp.Effects.lineMsg(.capture_line),
                .on_exit = InspectorApp.Effects.exitMsg(.capture_exit),
            });
        },
        .stop_capture => fx.cancel(model.live.key),
        else => {},
    }
    // A critical live failure queues an OS notification (workspace.zig decides;
    // deduped per code per session). The effects channel exposes no notification
    // verb, so reach the loop-thread-bound platform services directly (ADR-0011).
    // Fire only when a notifier is present — a null-services build (tests / null
    // platform) stays a silent no-op — then clear the queue regardless (bounding
    // it) so a serviceless build can't accumulate.
    if (fx.services) |services| {
        for (model.pendingNotifications()) |n| {
            services.showNotification(.{ .title = n.title(), .body = n.body() }) catch {};
        }
    }
    model.clearNotifications();
}

pub fn main(init: std.process.Init) !void {
    // Second face: if argv names a CLI subcommand, run it to completion and exit
    // BEFORE any window/app setup — no GUI is created. A bare trace path (or no
    // args) returns null and falls through to the inspector below.
    if (cli.maybeRun(init)) |code| std.process.exit(code);

    // The app struct (and the Model) are multi-MB: `create` heap-allocates and
    // constructs in place so neither rides the stack.
    const app_state = try InspectorApp.create(std.heap.page_allocator, .{
        .name = "studio",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = updateFx,
        .view = view,
    });
    defer app_state.destroy();
    app_state.model = .{ .backing = std.heap.page_allocator };
    defer app_state.model.deinitAll();

    openTracesFromArgs(&app_state.model, init);

    try runner.runWithOptions(app_state.app(), .{
        .app_name = "studio",
        .window_title = "OCPP DebugKit Studio",
        .bundle_id = "io.github.ocpp-debugkit.studio",
        .icon_path = "assets/icon.png",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .restore_state = false,
        .js_window_api = false,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
    }, init);
}

/// Read every trace path passed on the command line into the workspace. A file
/// that cannot be read opens as an error trace rather than aborting startup, so
/// one bad path never sinks the others.
fn openTracesFromArgs(model: *Model, init: std.process.Init) void {
    const alloc = std.heap.page_allocator;
    const args = init.minimal.args.toSlice(alloc) catch return;
    defer alloc.free(args);
    if (args.len > 0) model.setSelfExe(args[0]);
    if (args.len <= 1) return;
    for (args[1..]) |path| {
        const name = std.fs.path.basename(path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(init.io, path, alloc, .limited(max_trace_file_bytes)) catch |err| {
            model.openLoadError(name, @errorName(err));
            continue;
        };
        defer alloc.free(bytes);
        model.openBytes(name, bytes);
    }
}

test {
    _ = @import("tests.zig");
    _ = @import("ocpp/ocpp.zig");
    _ = @import("ui/ui.zig");
    _ = @import("cli.zig");
    _ = @import("capture/capture.zig");
}
