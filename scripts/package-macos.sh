#!/usr/bin/env bash
#
# Package the macOS app as "OCPP DebugKit Studio.app" inside a .dmg.
#
# `native package` is run against the default bundle name `studio.app` and then
# renamed, rather than packaged straight to the display name via `--output`,
# because the SDK's codesign invocation does not quote the bundle path: a path
# with spaces splits into multiple arguments and ad-hoc signing silently fails,
# leaving an unsigned bundle (which will not launch on Apple silicon). Signing
# the space-free name and renaming afterwards keeps the seal intact - the ad-hoc
# signature covers bundle contents, not the directory name - and we build the
# .dmg ourselves so it wraps the renamed, signed bundle.
#
# Usage: scripts/package-macos.sh <version>   (run after `native build`)
set -euo pipefail

version="${1:?usage: package-macos.sh <version>}"
out="zig-out/package"
app="$out/OCPP DebugKit Studio.app"
dmg="$out/studio-${version}-macos-ReleaseFast.dmg"

rm -rf "$out"
native package --target macos --signing adhoc
mv "$out/studio.app" "$app"

# Fail loudly if the rename ever stops preserving the signature: an unsigned
# arm64 bundle would ship broken.
codesign --verify --deep --strict "$app"

rm -f "$dmg"
hdiutil create -volname "OCPP DebugKit Studio" -srcfolder "$app" \
  -ov -format UDZO "$dmg"

echo "packaged: $app"
echo "archive:  $dmg"
