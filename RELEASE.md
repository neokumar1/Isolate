# Build, test, and release

## Local verification

Use Xcode 26.2 or newer and regenerate from `project.yml`:

```sh
xcodegen generate
TEST_RUNNER_ISOLATE_REQUIRE_MODEL=1 xcodebuild test -project Isolate.xcodeproj -scheme Isolate \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData \
  -only-testing:IsolateTests CODE_SIGNING_ALLOWED=NO
xcodebuild test -project Isolate.xcodeproj -scheme Isolate \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData \
  -only-testing:IsolateUITests
```

Unit tests create synthetic audio rather than relying on personal music files. With the model installed (see [MODEL.md](MODEL.md)), `TEST_RUNNER_ISOLATE_REQUIRE_MODEL=1` makes a missing model fail instead of skipping. An installed model that cannot run always fails unless `TEST_RUNNER_ISOLATE_ALLOW_INCOMPATIBLE_MODEL=1` explicitly enables the older-OS compatibility check. Keep that override off for release validation: safe refusal is not successful inference. Xcode strips `TEST_RUNNER_` when forwarding these variables; unprefixed variables in the invoking shell do not enforce the gate. A few real-time engine tests skip when no audio output device can start, as on hosted runners. The stem alignment test also skips if the output provides no render timeline and player start calls take over 0.5 seconds; that host cannot establish real-time alignment.

Before a release, also separate real music. Point `TEST_RUNNER_ISOLATE_REAL_AUDIO_DIR` at a folder of a few songs in different formats (for example an ALAC `.m4a`, a long MP3 and a file with punctuation in its name); the files are only read:

```sh
TEST_RUNNER_ISOLATE_REAL_AUDIO_DIR="$HOME/Music/Isolate check" TEST_RUNNER_ISOLATE_REQUIRE_MODEL=1 \
  xcodebuild test -project Isolate.xcodeproj -scheme Isolate -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData -only-testing:IsolateTests/RealMusicSmokeTests CODE_SIGNING_ALLOWED=NO
```

It checks that every song separates into four finite stereo stems with the original's length, that each stem carries audio, and that the stems add back up to the decoded original above a 10 dB reconstruction ratio. It prints speed and reconstruction per song; the latest three-source check measured about 23–30 dB. Ordinary runs skip it.

UI tests take over the mouse and keyboard, so run them on a logged-in desktop you are not using, with Xcode UI automation permission. They launch an isolated empty library and keep screenshots in the `.xcresult` bundle. The complete import, playback, export and delete workflow needs the local model.

## Version

`project.yml` is the source of truth. Set `CFBundleShortVersionString` and `CFBundleVersion` there (1.3.0 uses `1.3.0` for both), run `xcodegen generate`, and commit the regenerated `Info.plist`. Add a `## [x.y.z]` section to [CHANGELOG.md](CHANGELOG.md); the release notes are built from it. Then check that everything agrees with the tag you intend to push:

```sh
bash scripts/check_version.sh v1.3.0
bash scripts/release_notes.sh v1.3.0
```

Never reuse a tag or overwrite a published version's artifacts.

## Package locally

```sh
ISOLATE_DIST_DIR=/private/tmp/IsolateReleaseCheck \
ISOLATE_MODEL_PATH="$HOME/Library/Application Support/Isolate/HTDemucs.mlmodelc" \
  bash scripts/package_release.sh v1.3.0
```

The script stops before building if the tag, `project.yml` and `Info.plist` disagree. It then validates the reference model, builds Release for arm64 in a temporary directory, checks the built app's version, bundles the model (the licenses are app resources), signs the app with the hardened runtime and verifies the signature, and builds the DMG. The DMG is created writable so its volume can carry the custom-icon flag, then compressed and verified. It writes `Isolate.dmg`, `Isolate-<tag>-macOS.zip` and `SHA256SUMS.txt` to the dist directory. It does not install, commit, tag, push, or publish anything. For v1.3.0 on the development Mac it produced a 160 MB DMG, a 148 MB ZIP and a 313 MB app (decimal megabytes, as Finder reports them).

Default signing is ad hoc, now with the hardened runtime. For Developer ID distribution, supply `ISOLATE_SIGNING_IDENTITY` and an `ISOLATE_NOTARY_PROFILE` already stored in your keychain. The script submits the app to Apple's notary service and staples it before packaging. Verify Gatekeeper on a freshly downloaded artifact before public release. Never place signing credentials in Git.

The app icon's source is `Sources/Resources/AppIcon.icon`, with four SVG layers and system-rendered materials. Xcode compiles its layered representations and generates the compatibility ICNS for older macOS versions. `CFBundleIconName` and the app-icon build setting both name `AppIcon`; the separately tracked legacy ICNS is excluded from the app resource phase to avoid duplicate outputs.

With **Xcode 27 selected**, run `swift scripts/generate_assets.swift` from the repository root to regenerate the macOS 27 preview, the DMG/legacy ICNS files at 16–1024 px, and the 144-dpi DMG background. Commit `Assets/AppIcon-macOS27.png`, `Assets/AppIcon.icns`, `Sources/Resources/AppIcon.icns`, and `Assets/dmg_background.png` together with icon source changes. Ordinary builds use the committed sources and do not run this generator. See [Apple's Icon Composer guidance](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer).

## GitHub Actions

- **Build & Test** runs on pushes and pull requests to `main`, on both `macos-15` and `macos-26`. It checks every shell script's syntax, the cask's Ruby syntax, that `Info.plist` matches `project.yml`, and whitespace; builds Release; and runs the unit and audio tests. When the model variables are available it fetches the pinned model and requires real inference on macOS 26. macOS 15 explicitly allows the verified refusal of its incompatible Core ML runtime, with inference tests reported as skipped; a missing model still fails. Fork pull requests skip missing-model inference with a notice. Test results are kept as `.xcresult` artifacts.
- **Prepare Release Draft** runs on a `v*` tag. Its first step compares the tag with `project.yml`, `Info.plist` and `CHANGELOG.md`, so a mismatch fails in seconds. It then fetches the pinned model, runs the model-backed unit tests, packages, and creates a **draft** release named `Isolate <tag>` with the DMG, the ZIP and the checksums. The draft's notes come from `scripts/release_notes.sh`: what to download, first-launch steps for macOS 15+ and 14, and the CHANGELOG section. Reminders for the maintainer go to the job summary, not the notes.
- `workflow_dispatch` must be run against a version tag, not a branch.
- Interactive UI tests are a local release gate because hosted runners do not provide a dependable logged-in desktop.

## Publication checks

1. Confirm model provenance, the immutable download and checksum, source order, and bundled notices.
2. Pass unit tests with the model required, UI tests, the Release build, and local package validation.
3. Smoke-test import, cancellation, playback, audio-device switching, export, relaunch, deletion and the upgrade from a pre-1.3 library on the minimum supported macOS and a current stable macOS.
4. Listen to separated musical material to assess stem identity and artifacts; synthetic tests do not establish perceptual quality.
5. Download the draft's DMG in a browser and walk through the README's [First launch](README.md#first-launch) steps on macOS 15 or later and on macOS 14. If the build is ever Developer ID signed and notarized, update the README, the release notes script and the cask caveats to match.
6. Merge the release branch into `main` (use a merge commit so the tagged commit stays in `main`'s history). The release notes' and cask's `#first-launch` links, the issue templates, the `install.sh` URL in INSTALL.md and the Homebrew tap all read `main`.
7. Review the draft's notes, version and checksums, then publish it and mark it as the latest release. The README's download link and `install.sh` follow the latest release, so publish and merge before announcing, then confirm that https://github.com/neokumar1/Isolate#first-launch opens the First launch section.
8. Commit the cask's `version` and `sha256` for the published `Isolate.dmg` to `main` together, and check it with `brew install --cask neokumar1/isolate/isolate` on a clean Mac.
9. Keep the model archive's prerelease unpublished as Latest. Consider editing older release notes that recommend `xattr -cr` or Control-click on macOS 15 and later.

See [QUALITY_REPORT.md](QUALITY_REPORT.md) for this checkout's measured verification and remaining external release gates.
