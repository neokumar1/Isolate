# 🔧 Isolate Troubleshooting & FAQ

### 1. macOS Gatekeeper: "Apple could not verify Isolate.app is free of malware"

#### Why does this happen?
When an app is downloaded from the internet using a web browser (Safari, Chrome, etc.), macOS automatically tags the file with a `com.apple.quarantine` extended attribute. Because Isolate is free, open-source software built without a $99/year Apple Developer ID certificate, macOS Gatekeeper blocks direct execution on first double-click.

#### Solutions:

##### Option 1: 1-Line Terminal Fix (Recommended)
Run this command in Terminal:
```bash
xattr -cr /Applications/Isolate.app
```
*(This permanently strips the quarantine attribute. You will never see the warning again).*

##### Option 2: macOS Sequoia / Sonoma GUI Settings
1. Click **Done** on the alert dialog.
2. Open **System Settings** on your Mac.
3. Click **Privacy & Security** in the sidebar.
4. Scroll down to the **Security** header.
5. You will see: *"Isolate.app was blocked to protect your Mac"*.
6. Click **Open Anyway**.
7. Enter your Mac password or Touch ID and click **Open**.

##### Option 3: Reinstall via Terminal (Zero Warnings)
Run the automated curl installer:
```bash
curl -fsSL https://raw.githubusercontent.com/neokumar1/Isolate/main/install.sh | bash
```

---

### 2. Audio Processing Speed & Hardware Acceleration

- **Apple Silicon Neural Engine (ANE)**: Isolate is compiled for `arm64` with CoreML `all` compute units. Neural stem splitting runs directly on the Apple Neural Engine and GPU.
- **Audio Formats Supported**: `.mp3`, `.wav`, `.m4a`, `.aac`, `.flac`, `.aiff`.

---

### 3. Resetting App State
If you ever want to reset all cached waveforms or settings:
```bash
rm -rf ~/Library/Application\ Support/Isolate
rm -f ~/Library/Preferences/com.isolate.Isolate.plist
```
