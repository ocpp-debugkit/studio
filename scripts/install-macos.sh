#!/usr/bin/env bash
#
# One-line installer for OCPP DebugKit Studio (macOS, Apple silicon):
#
#   curl -fsSL https://raw.githubusercontent.com/ocpp-debugkit/studio/main/scripts/install-macos.sh | bash
#
# Fetches the latest release DMG, verifies its SHA-256 against the release's
# published SHA256SUMS, installs the app to /Applications, clears the download
# quarantine, and opens it. No toolchain, no manual steps.
#
# The checksum and the DMG are both served from the GitHub release over HTTPS, so
# this verifies integrity (a corrupt or truncated download is rejected); it is not
# an independent code signature.
set -euo pipefail

repo="ocpp-debugkit/studio"
app="OCPP DebugKit Studio.app"
dest="/Applications/$app"
base="https://github.com/$repo/releases/latest/download"

note() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "This installer is macOS-only. On Linux, grab the .tar.gz from https://github.com/$repo/releases."
[ "$(uname -m)" = "arm64" ] || fail "OCPP DebugKit Studio ships an Apple-silicon (arm64) build; this Mac is $(uname -m)."

mnt=""
tmp="$(mktemp -d)"
cleanup() {
  [ -n "$mnt" ] && hdiutil detach "$mnt" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

note "Finding the latest release"
sums="$(curl -fsSL "$base/SHA256SUMS")" || fail "could not fetch release checksums"
line="$(printf '%s\n' "$sums" | grep 'macos-ReleaseFast\.dmg$')" || fail "the latest release has no macOS build"
sha="${line%% *}"
name="${line##* }"

note "Downloading $name"
curl -fSL --progress-bar -o "$tmp/$name" "$base/$name" || fail "download failed"

note "Verifying SHA-256"
got="$(shasum -a 256 "$tmp/$name" | awk '{ print $1 }')"
[ "$got" = "$sha" ] || fail "checksum mismatch - expected $sha, got $got (not installing)"

note "Mounting the disk image"
mnt="$(hdiutil attach "$tmp/$name" -nobrowse -readonly | grep -o '/Volumes/.*' | head -1)"
[ -n "$mnt" ] || fail "could not mount the disk image"

sudo=""
if [ ! -w /Applications ]; then
  sudo="sudo"
  note "/Applications needs administrator access - you may be prompted for your password"
fi

note "Installing to /Applications"
$sudo rm -rf "$dest"
$sudo ditto "$mnt/$app" "$dest"

# The app copied out of a curl-downloaded DMG normally has no quarantine flag
# (curl does not set one), but clear it defensively so the first launch never
# hits Gatekeeper. Harmless if the attribute is absent.
$sudo xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true

note "Opening $app"
open "$dest"
note "Done - OCPP DebugKit Studio is installed in /Applications."
