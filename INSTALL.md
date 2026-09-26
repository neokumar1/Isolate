# Install and build Isolate

Isolate needs a Mac with Apple silicon (M1 or later) and macOS 14 Sonoma or later.

## Disk image (recommended)

1. Download `Isolate.dmg` from the [latest release](https://github.com/neokumar1/Isolate/releases/latest). It is about 160 MB.
2. Open the disk image and drag Isolate into Applications. Quit a running copy before replacing it.
3. Open Isolate from Applications and approve the first launch as described in the README's [First launch](README.md#first-launch) section.

The app takes about 313 MB once installed, because the separation model is inside it (`Isolate.app/Contents/Resources/HTDemucs.mlmodelc`). Releases are ad-hoc signed and are not notarized by Apple. Approve Isolate in **System Settings › Privacy & Security** rather than disabling Gatekeeper or clearing quarantine attributes.

To check a download, compare `shasum -a 256 Isolate.dmg` with the value in the release's `SHA256SUMS.txt`. A checksum published in the same release confirms the file arrived intact; it does not prove who published it.

If you open Isolate straight from the disk image, it offers to move itself to Applications. If Applications already has a copy, it asks before replacing it and moves the old copy to the Trash.

## Homebrew

The cask lives in this repository rather than in Homebrew's main tap, so tap it by URL:

```sh
brew tap neokumar1/isolate https://github.com/neokumar1/Isolate
brew install --cask neokumar1/isolate/isolate
```

Homebrew quarantines the app like a browser download, so the first launch needs the same approval. `brew uninstall --zap --cask neokumar1/isolate/isolate` also removes the library, the separated stems and the preferences.

## Terminal installer

`install.sh` installs the latest release into `/Applications`. Download and read it before running it:

```sh
curl -fsSLO https://raw.githubusercontent.com/neokumar1/Isolate/main/install.sh
less install.sh
bash install.sh
```

It resolves the latest version once, downloads `SHA256SUMS.txt` before the disk image and stops if the checksum is missing or does not match. It also checks the app's code signature and that the model is bundled, and it stages the new copy before replacing an existing one. Run it from an administrator account; it will not install into a folder it cannot write. Because curl does not mark downloads as quarantined, macOS usually does not ask you to approve the first launch of an app installed this way.

## Build from source

Install Xcode 26.2 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The deployment target stays macOS 14.

```sh
brew install xcodegen
xcodegen generate
xcodebuild build -project Isolate.xcodeproj -scheme Isolate \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData
open build/DerivedData/Build/Products/Debug/Isolate.app
```

The app needs no Python runtime and no third-party Swift packages. The Core ML model is not in the repository; follow [MODEL.md](MODEL.md) to install the validated model. Without it the app builds and plays songs that were already separated, but it cannot separate new ones.

## Where Isolate keeps its data

| Data | Location |
| --- | --- |
| Library | `~/Library/Application Support/Isolate/Library.store` |
| Library backups | `~/Library/Application Support/Isolate/Library Backups/<date and time>/` |
| Separated stems | `~/Library/Application Support/Isolate/Stems/` |
| Model for source builds | `~/Library/Application Support/Isolate/HTDemucs.mlmodelc` (the bundled model is used first) |
| Preferences | the `com.isolate.Isolate` user defaults domain |

Your original audio files stay where they are; Isolate only reads them. Each separated song uses about 106 MB per minute of audio in the stems folder: 32-bit float copies of the four stems and of the decoded original.

Versions before 1.3 kept the library in the shared `~/Library/Application Support/default.store`. On its first launch, 1.3 copies your songs out of a temporary copy of that file into `Library.store`. It never opens, changes or deletes `default.store` itself, because other apps can use the same file. If `Library.store` ever cannot be opened, Isolate moves it into `Library Backups` and starts a new library; see [TROUBLESHOOTING.md](TROUBLESHOOTING.md#the-library-is-empty-or-was-moved-to-library-backups).

Deleting a song in Isolate removes only the stem folder it owns, and only when no other library entry uses it. Quit Isolate and back up `~/Library/Application Support/Isolate` before changing anything in it by hand.

## Uninstall

Quit Isolate and move `/Applications/Isolate.app` to the Trash. To remove your library and separated stems too, delete `~/Library/Application Support/Isolate`. Your original audio files are not affected.
