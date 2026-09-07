# Installation Guide

Isolate is a standalone macOS application. You do not need Python, Node.js, Docker, or any external runtimes to install and run it.

---

## Method 1: Homebrew Cask (recommended)

```bash
brew install --cask TheConfidentCoder/isolate/isolate
```

To update in the future:

```bash
brew upgrade isolate
```

---

## Method 2: Direct download (DMG)

1. Download `Isolate.dmg` from [Releases](https://github.com/TheConfidentCoder/Isolate/releases/latest).
2. Open the disk image and drag `Isolate.app` into your `/Applications` folder.
3. Open `Isolate.app` from Applications.

### Gatekeeper note

Because Isolate is an independent open-source project without a paid Apple Developer certificate, macOS may show a prompt saying the developer cannot be verified on first launch.

To open the app:
- **Terminal**: Run `xattr -cr /Applications/Isolate.app`
- **System Settings**: Open **System Settings** > **Privacy & Security**, scroll down to Security, and click **Open Anyway**.

---

## Method 3: Terminal install script

```bash
curl -fsSL https://raw.githubusercontent.com/TheConfidentCoder/Isolate/main/install.sh | bash
```

---

## Method 4: Build from source

Prerequisites: Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
git clone https://github.com/TheConfidentCoder/Isolate.git
cd Isolate
xcodegen generate
xcodebuild -scheme Isolate -configuration Release -destination 'platform=macOS' build
open build/Release/Isolate.app
```
