# Install and build Isolate

## Release app

The public v1.2.7 DMG inspected on September 21, 2026 does **not** include the separation model or app version metadata. The v1.2.8 work in this checkout fixes packaging, but has not been published. Use the source-build instructions and [MODEL.md](MODEL.md) until a complete release is available. The terminal installer intentionally rejects releases missing checksums or the model.

1. Use an Apple Silicon Mac running macOS 14 or later.
2. Download `Isolate.dmg` from the project's [Releases](https://github.com/neokumar1/Isolate/releases).
3. Open the disk image and drag Isolate into Applications. Quit a running copy before replacing it.
4. Launch the app from Applications. Release packages must contain `Contents/Resources/HTDemucs.mlmodelc`.

If macOS blocks an unsigned or unnotarized build, verify where it came from and review **System Settings → Privacy & Security → Open Anyway**. Do not disable Gatekeeper or recursively clear quarantine. Signing and notarization status belongs in each release's notes.

The Homebrew cask in `Casks/isolate.rb` describes the existing 1.2.5 release. Its version and checksum must be updated together only after a new artifact has been published and verified.

## Optional terminal installer

Download and inspect `install.sh` before running it. It pins the latest release version for the duration of installation, checks the DMG against its release checksum, verifies the app signature, and requires the bundled model. It stages the app before replacing an existing installation. A checksum fetched from the same release checks integrity, not independent publisher identity.

## Build from source

Install Xcode 26.2 or newer, select it with Xcode's Locations preferences, and install XcodeGen. The deployment target remains macOS 14.

```sh
brew install xcodegen
xcodegen generate
xcodebuild build -project Isolate.xcodeproj -scheme Isolate \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData
open build/DerivedData/Build/Products/Debug/Isolate.app
```

No Python runtime or third-party Swift dependencies are needed by the app. The Core ML model is a separate build input; follow [MODEL.md](MODEL.md). Without it, the UI builds and existing valid cached stems can play, but new separation cannot run.

## Local data

- Library: SwiftData's application store under the app's Application Support location.
- Model: bundled resources first, then `~/Library/Application Support/Isolate/HTDemucs.mlmodelc`.
- Audio cache: `~/Library/Application Support/Isolate/Stems/`.
- Preferences: `com.isolate.Isolate` user defaults.

Removing a library entry removes only its owned, unshared stem cache. Original source files are not deleted. Keep original files available if cached stems need rebuilding. Quit Isolate and back up the library/cache before manually changing app data.
