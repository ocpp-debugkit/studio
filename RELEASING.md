# Releasing OCPP DebugKit Studio

Studio ships as a native binary per OS, cut from `main` via a tag. Releases are
pre-1.0 (0.x) while Zig, the Native SDK, and the toolkit conformance reference
are all pre-1.0 — see the [ROADMAP](ROADMAP.md) versioning note.

## What a release produces

A push of a `vX.Y.Z` tag triggers [`.github/workflows/release.yml`](.github/workflows/release.yml),
which builds and publishes a GitHub release with two artifacts:

| Platform | Artifact | Notes |
| --- | --- | --- |
| macOS | `studio-X.Y.Z-macos-ReleaseFast.dmg` | A `.app` bundle, **ad-hoc signed** |
| Linux | `studio-X.Y.Z-linux-ReleaseFast.tar.gz` | The `studio` binary + resources |
| both | `SHA256SUMS` | Checksums of both packages; the installer verifies against it |

**macOS install:** users install with the one-line installer
([`scripts/install-macos.sh`](scripts/install-macos.sh); see the README), which
downloads the latest DMG, verifies its SHA-256 against `SHA256SUMS`, installs the
app, and clears the download quarantine. The build is ad-hoc signed, not notarized
(a deliberate tradeoff) — installing via `curl` sidesteps the browser-download
quarantine, so the first launch is clean.

## Cutting a release

1. **Green `main`.** CI must be green on the commit you are releasing.
2. **Bump the version** in [`app.zon`](app.zon) (`.version = "X.Y.Z"`).
3. **Finalize the changelog** — move the `Unreleased` section of
   [`CHANGELOG.md`](CHANGELOG.md) under a dated `X.Y.Z` heading.
4. **Update the living docs** — `CURRENT_STATE.md` / `ROADMAP.md` as needed.
5. Land 2–4 through a normal PR and merge to `main`.
6. **Tag and push** from the merged commit:
   ```sh
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```
7. The release workflow builds both packages and publishes the GitHub release
   (`--generate-notes` for the auto notes; swap to `--notes-file` from the
   changelog section if you prefer curated notes).

The tag and the published release are **outward-facing and hard to reverse** —
push the tag only when the release commit is final.

## Verifying packaging locally

Build a package without cutting a release (macOS):

```sh
native build
scripts/package-macos.sh 0.5.1
# → zig-out/package/OCPP DebugKit Studio.app  and  zig-out/package/studio-0.5.1-macos-ReleaseFast.dmg
open "zig-out/package/OCPP DebugKit Studio.app"   # smoke-launch it
```

[`scripts/package-macos.sh`](scripts/package-macos.sh) signs `studio.app`, renames
it to the display name, and builds the `.dmg` — see the script header for why the
rename can't go through `native package --output` directly. `native doctor
--strict` gates the manifest; the release workflow runs it too.
