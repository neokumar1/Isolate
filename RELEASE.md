# Build, test, and release

## Local verification

Use Xcode 26.2 or newer and regenerate from `project.yml`:

```sh
xcodegen generate
xcodebuild test -project Isolate.xcodeproj -scheme Isolate \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData \
  -only-testing:IsolateTests CODE_SIGNING_ALLOWED=NO
xcodebuild test -project Isolate.xcodeproj -scheme Isolate \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData \
  -only-testing:IsolateUITests
```

UI tests need a logged-in desktop and Xcode UI automation permission. They launch an isolated empty library and preserve screenshots in the `.xcresult` bundle. The complete import/playback/export/delete UI workflow requires the local model. Tests create synthetic audio rather than relying on personal music files. Unit inference skips when the model is absent in ordinary source CI; run `TEST_RUNNER_ISOLATE_REQUIRE_MODEL=1 xcodebuild test ...` for a release gate. Xcode strips `TEST_RUNNER_` when forwarding the variable to test processes; setting only `ISOLATE_REQUIRE_MODEL` in the invoking shell does not enforce this gate.

## Package locally

Update both version values in `project.yml`, regenerate, and use the matching tag. Do not overwrite a published version's artifacts.

```sh
ISOLATE_DIST_DIR=/private/tmp/IsolateReleaseCheck \
ISOLATE_MODEL_PATH="$HOME/Library/Application Support/Isolate/HTDemucs.mlmodelc" \
  bash scripts/package_release.sh v1.2.8
```

The script validates the reference model, builds Release for arm64, bundles the model and licenses, signs the app, verifies the signature, creates/verifies the DMG, and writes a ZIP and checksums. It operates in a temporary build directory. It does not install, commit, tag, push, or publish anything.

Default signing is ad hoc for local evaluation. For Developer ID distribution, supply `ISOLATE_SIGNING_IDENTITY` and an `ISOLATE_NOTARY_PROFILE` already stored in your keychain. The script submits the app to Apple's notary service and staples it before packaging. Verify Gatekeeper on a freshly downloaded artifact before public release. Never place signing credentials in Git.

## GitHub Actions

- Pull requests/main builds: Release compilation, unit/audio tests, saved `.xcresult` artifacts.
- Tagged release: requires the model URL/checksum from [MODEL.md](MODEL.md), runs model-backed unit tests, builds packages, creates a **draft** GitHub release.
- `workflow_dispatch` must be run against a version tag, not a branch.
- Interactive UI tests are a local release gate because hosted runners do not provide a dependable logged-in desktop.

## Publication checks

1. Confirm model provenance, immutable download/checksum, source order, and bundled notices.
2. Pass unit tests with model required, UI tests, Release build, and package validation.
3. Smoke-test import, cancellation, playback, audio-device switching, export, relaunch, and deletion on the minimum supported macOS and a current stable macOS.
4. Listen to separated musical material to assess stem identity and artifacts; synthetic tests do not establish perceptual quality.
5. Verify Developer ID/notarization if distributing as a notarized app, or clearly label an ad-hoc build.
6. Review draft release contents, version and checksums; update the cask only against the final artifact.

See [QUALITY_REPORT.md](QUALITY_REPORT.md) for this checkout's measured verification and remaining external release gates.
