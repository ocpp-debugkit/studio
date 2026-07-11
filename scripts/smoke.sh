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

if [ ! -x "$BIN" ]; then
  echo "smoke: $BIN not found — build first: native build -Dautomation=true" >&2
  exit 1
fi

# Start from a clean automation dir so 'wait' only sees this run.
rm -rf "$AUTO_DIR"

if command -v xvfb-run >/dev/null 2>&1; then
  xvfb-run -a "$BIN" &
else
  "$BIN" &
fi
APP_PID=$!
trap 'kill "$APP_PID" >/dev/null 2>&1 || true' EXIT

# Block until the runtime publishes ready=true (or fail loudly on timeout).
native automate wait --timeout-ms 60000

# The window must exist with the expected, non-blank widget tree.
native automate assert --timeout-ms 30000 \
  'ready=true' \
  'gpu_nonblank=true' \
  'role=button name="Reset"' \
  'role=button name="\+"' \
  'role=button name="-"' \
  'OCPP DebugKit Studio' \
  'count: 0'

# No runtime/dispatch errors surfaced during startup.
native automate assert --absent 'error event='

# A real-pixel capture must land as a non-empty PNG.
native automate screenshot main-canvas
test -s "$AUTO_DIR/screenshot-main-canvas.png"

echo "smoke: ok — window rendered and automation drove the widget tree"
