#!/usr/bin/env bash
#
# Automation smoke test: launch the app, wait for its embedded automation
# server, assert the widget tree actually rendered, and capture a
# deterministic screenshot artifact. Portable — uses a virtual framebuffer
# (Xvfb) when available (CI), otherwise runs the window directly (local
# macOS). The app must be built with -Dautomation=true.
#
set -euo pipefail

BIN=zig-out/bin/studio
AUTO_DIR=.zig-cache/native-sdk-automation
# Launch with the vendored sample as a command-line trace argument, so the smoke
# test exercises the real CLI load path and lands on the loaded overview.
SAMPLE=src/ocpp/testdata/normal-session.json

if [ ! -x "$BIN" ]; then
  echo "smoke: $BIN not found — build first: native build -Dautomation=true" >&2
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

# Block until the runtime publishes ready=true (or fail loudly on timeout).
native automate wait --timeout-ms 60000

# The window must exist with the loaded trace rendered. The app was launched
# with the sample trace as a command-line argument, so it opens straight on the
# overview — proving the CLI load → parse → render path works end to end. These
# assertions read the semantics snapshot (GPU-independent), so they hold under
# software GL too.
native automate assert --timeout-ms 30000 \
  'ready=true' \
  'normal-session.json' \
  'BootNotification' \
  '22 events' \
  'OCPP DebugKit Studio'

# No runtime/dispatch errors surfaced during startup.
native automate assert --absent 'error event='

# A real-pixel capture must land as a non-empty PNG.
native automate screenshot main-canvas
test -s "$AUTO_DIR/screenshot-main-canvas.png"

echo "smoke: ok — window rendered and automation drove the inspector"
