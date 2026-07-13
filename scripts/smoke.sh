#!/usr/bin/env bash
#
# Automation-driven GUI test: launch the app, wait for its embedded automation
# server, then DRIVE the headline flows through the automation protocol -
# clicking real widgets and asserting the rendered semantics tree after each
# step - and capture deterministic screenshots as artifacts. Portable: uses a
# virtual framebuffer (Xvfb) when available (CI), otherwise runs the window
# directly (local macOS). The app must be built with -Dautomation=true.
#
set -euo pipefail

BIN=zig-out/bin/studio
AUTO_DIR=.zig-cache/native-sdk-automation
CANVAS=main-canvas
# Launch with the vendored sample as a command-line trace argument, so the test
# exercises the real CLI load path and lands on the loaded overview.
SAMPLE=src/ocpp/testdata/normal-session.json

if [ ! -x "$BIN" ]; then
  echo "smoke: $BIN not found - build first: native build -Dautomation=true" >&2
  exit 1
fi

# Start from a clean automation dir so 'wait' only sees this run.
rm -rf "$AUTO_DIR"

# Headless GTK needs no accessibility bus; without this the app aborts on a
# missing a11y DBus service. A private session bus (dbus-run-session) then
# satisfies the runtime's DBus handshake. Both are no-ops on macOS.
export GTK_A11Y=none
export NO_AT_BRIDGE=1

launch() {
  if command -v xvfb-run >/dev/null 2>&1; then
    if command -v dbus-run-session >/dev/null 2>&1; then
      dbus-run-session -- xvfb-run -a "$BIN" "$SAMPLE"
    else
      xvfb-run -a "$BIN" "$SAMPLE"
    fi
  else
    "$BIN" "$SAMPLE"
  fi
}

launch &
APP_PID=$!
trap 'kill "$APP_PID" >/dev/null 2>&1 || true' EXIT

# The numeric widget id for the widget whose accessibility name equals $1. Each
# snapshot line is `widget @w<win>/<view>#<id> role=<r> name="<label>" ...`; anchor
# on the id in that path so a name never mismatches. Prefer the `snapshot`
# command's output (a fresh publish); fall back to the dropbox snapshot.txt.
widget_id() {
  local snap
  snap="$(native automate snapshot 2>/dev/null || true)"
  [ -n "$snap" ] || snap="$(cat "$AUTO_DIR/snapshot.txt" 2>/dev/null || true)"
  printf '%s\n' "$snap" | grep -F "name=\"$1\"" \
    | sed -E 's/^.*@w[0-9]+\/[a-z0-9-]+#([0-9]+) role=.*/\1/' | head -n1
}

# Click the widget named $1 (fails loudly, dumping the tree, if it is absent).
click() {
  local id
  id="$(widget_id "$1" || true)"
  if [ -z "$id" ]; then
    echo "gui-test: no widget named \"$1\" in the snapshot:" >&2
    native automate snapshot >&2 || true
    exit 1
  fi
  native automate widget-click "$CANVAS" "$id"
}

shot() { # capture the canvas to a stably-named PNG artifact ($1)
  native automate screenshot "$CANVAS"
  cp "$AUTO_DIR/screenshot-$CANVAS.png" "$AUTO_DIR/screenshot-$1.png"
  test -s "$AUTO_DIR/screenshot-$1.png"
}

# Block until the runtime publishes ready=true (or fail loudly on timeout).
native automate wait --timeout-ms 60000

# 1. The CLI load -> parse -> render path: launched with the sample trace, the app
#    opens straight on the overview. Assertions read the semantics snapshot
#    (GPU-independent), so they hold under software GL too.
native automate assert --timeout-ms 30000 \
  'ready=true' \
  'normal-session.json' \
  'BootNotification' \
  '22 events' \
  'OCPP DebugKit Studio'

# 2. Drive the replay transport: with nothing selected, Next selects the first
#    event, and the detail pane unpacks it.
click 'Next'
native automate assert --timeout-ms 30000 'Details' 'evt-0001' 'Message ID'
shot inspector

# 3. Drive the filter: the Call facet narrows the timeline (the status bar counts
#    the match subset), and Clear restores the full set.
click 'Call'
native automate assert --timeout-ms 30000 'of 22 events'
click 'Clear'
native automate assert --absent --timeout-ms 30000 'of 22 events'

# 4. Switch to the live-capture surface: its control strip renders (endpoints +
#    start control + the idle note). No capture is started - that would spawn a
#    real proxy subprocess.
click 'Live'
native automate assert --timeout-ms 30000 'Start capture' 'Ready to capture' 'Listen'
shot live

# 5. No runtime/dispatch errors surfaced across the whole run.
native automate assert --absent 'error event='

echo "smoke: ok - automation drove the inspector, filter, and live surface"
