#!/bin/bash
set -euo pipefail

[[ "$(uname -s)" == Darwin ]] || { echo "Isolate requires macOS." >&2; exit 1; }
[[ "$(uname -m)" == arm64 ]] || { echo "Isolate requires an Apple Silicon Mac." >&2; exit 1; }
OS_MAJOR=$(sw_vers -productVersion | cut -d. -f1)
[[ "$OS_MAJOR" -ge 14 ]] || { echo "Isolate requires macOS 14 or newer." >&2; exit 1; }
if pgrep -x Isolate >/dev/null; then
    echo "Quit Isolate before installing or updating it." >&2
    exit 1
fi
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/isolate-install.XXXXXX")
MOUNT_DIR="$WORK_DIR/volume"
APP_TARGET="/Applications/Isolate.app"
STAGED_APP="/Applications/.Isolate-install-$$.app"
BACKUP_APP="/Applications/.Isolate-backup-$$.app"
cleanup() {
    hdiutil detach "$MOUNT_DIR" -quiet 2>/dev/null || true
    rm -rf "$WORK_DIR" "$STAGED_APP"
    if [[ -d "$BACKUP_APP" && ! -e "$APP_TARGET" ]]; then mv "$BACKUP_APP" "$APP_TARGET"; fi
}
trap cleanup EXIT

# Resolve latest once so a concurrent release cannot mix checksums and binaries.
RELEASE_URL=$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/neokumar1/Isolate/releases/latest)
VERSION="${RELEASE_URL##*/}"
[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Could not resolve the release version." >&2; exit 1; }
BASE_URL="https://github.com/neokumar1/Isolate/releases/download/$VERSION"
curl -fL --retry 3 "$BASE_URL/Isolate.dmg" -o "$WORK_DIR/Isolate.dmg"
curl -fsSL --retry 3 "$BASE_URL/SHA256SUMS.txt" -o "$WORK_DIR/SHA256SUMS.txt"
EXPECTED=$(awk '$2 == "Isolate.dmg" && length($1) == 64 {print $1}' "$WORK_DIR/SHA256SUMS.txt")
ACTUAL=$(shasum -a 256 "$WORK_DIR/Isolate.dmg" | awk '{print $1}')
[[ -n "$EXPECTED" && "$EXPECTED" == "$ACTUAL" ]] || { echo "Download checksum mismatch; installation stopped." >&2; exit 1; }

hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT_DIR" "$WORK_DIR/Isolate.dmg" -quiet
codesign --verify --deep --strict "$MOUNT_DIR/Isolate.app"
[[ -d "$MOUNT_DIR/Isolate.app/Contents/Resources/HTDemucs.mlmodelc" ]] || { echo "Release model is missing." >&2; exit 1; }
ditto "$MOUNT_DIR/Isolate.app" "$STAGED_APP"
if [[ -e "$APP_TARGET" ]]; then mv "$APP_TARGET" "$BACKUP_APP"; fi
mv "$STAGED_APP" "$APP_TARGET"
if [[ -d "$BACKUP_APP" ]]; then rm -rf "$BACKUP_APP"; fi
printf 'Installed %s to %s\n' "$VERSION" "$APP_TARGET"
printf 'Open Isolate from Applications. If macOS blocks it, review Privacy & Security → Open Anyway.\n'
