#!/bin/bash
# Installs the latest Isolate release into /Applications after checking its
# checksum, code signature and bundled model. Read it before running it.
set -euo pipefail

RELEASES="https://github.com/neokumar1/Isolate/releases"
fail() { printf 'Isolate installer: %s\n' "$1" >&2; exit 1; }

[[ "$(uname -s)" == Darwin ]] || fail "Isolate requires macOS."
# uname reports x86_64 inside a Rosetta shell, so ask the hardware instead.
[[ "$(sysctl -n hw.optional.arm64 2>/dev/null)" == 1 ]] || fail "Isolate requires a Mac with Apple silicon."
OS_MAJOR=$(sw_vers -productVersion | cut -d. -f1)
[[ "$OS_MAJOR" -ge 14 ]] || fail "Isolate requires macOS 14 Sonoma or later."
if pgrep -x Isolate >/dev/null; then fail "Quit Isolate before installing or updating it."; fi
[[ -w /Applications ]] || fail "This account cannot write to /Applications. Run the installer from an administrator account, or open Isolate.dmg from ${RELEASES} and drag Isolate into Applications."

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/isolate-install.XXXXXX")
MOUNT_DIR="$WORK_DIR/volume"
APP_TARGET="/Applications/Isolate.app"
STAGED_APP="/Applications/.Isolate-install-$$.app"
BACKUP_APP="/Applications/.Isolate-backup-$$.app"
cleanup() {
    # Keep going so the previous copy is restored even if a step here fails.
    set +e
    hdiutil detach "$MOUNT_DIR" -quiet >/dev/null 2>&1
    rm -rf "$WORK_DIR" "$STAGED_APP" 2>/dev/null
    if [[ -d "$BACKUP_APP" && ! -e "$APP_TARGET" ]]; then mv "$BACKUP_APP" "$APP_TARGET"; fi
}
trap cleanup EXIT

# Resolve latest once so a concurrent release cannot mix checksums and binaries.
RELEASE_URL=$(curl -fsSL -o /dev/null -w '%{url_effective}' "$RELEASES/latest") \
    || fail "Could not reach GitHub. Check the internet connection and try again."
VERSION="${RELEASE_URL##*/}"
[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Could not work out the latest release from ${RELEASE_URL}."
BASE_URL="$RELEASES/download/$VERSION"
# Checksums first: a release without them is refused before the large download.
curl -fsSL --retry 3 "$BASE_URL/SHA256SUMS.txt" -o "$WORK_DIR/SHA256SUMS.txt" 2>/dev/null \
    || fail "Release ${VERSION} has no SHA256SUMS.txt, so it cannot be verified. Download Isolate.dmg from ${RELEASES} instead."
EXPECTED=$(awk '$2 == "Isolate.dmg" && length($1) == 64 {print $1}' "$WORK_DIR/SHA256SUMS.txt")
[[ -n "$EXPECTED" ]] || fail "Release ${VERSION} lists no checksum for Isolate.dmg."
printf 'Downloading Isolate %s...\n' "$VERSION"
curl -fL --retry 3 "$BASE_URL/Isolate.dmg" -o "$WORK_DIR/Isolate.dmg" || fail "The download of Isolate.dmg failed."
ACTUAL=$(shasum -a 256 "$WORK_DIR/Isolate.dmg" | awk '{print $1}')
[[ "$EXPECTED" == "$ACTUAL" ]] || fail "Download checksum mismatch; installation stopped."

hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$MOUNT_DIR" "$WORK_DIR/Isolate.dmg" -quiet \
    || fail "Could not open the downloaded disk image."
codesign --verify --deep --strict "$MOUNT_DIR/Isolate.app" || fail "The app's code signature did not verify; installation stopped."
[[ -d "$MOUNT_DIR/Isolate.app/Contents/Resources/HTDemucs.mlmodelc" ]] \
    || fail "Release ${VERSION} does not include the separation model; installation stopped."
ditto "$MOUNT_DIR/Isolate.app" "$STAGED_APP" || fail "Could not copy Isolate into /Applications."
if [[ -e "$APP_TARGET" ]]; then
    mv "$APP_TARGET" "$BACKUP_APP" || fail "Could not move the installed copy aside; it was left unchanged."
fi
mv "$STAGED_APP" "$APP_TARGET"
if [[ -d "$BACKUP_APP" ]] && ! rm -rf "$BACKUP_APP" 2>/dev/null; then
    printf 'Warning: the previous copy could not be removed. Delete it with: sudo rm -rf "%s"\n' "$BACKUP_APP" >&2
fi
printf 'Installed Isolate %s in %s.\n' "$VERSION" "$APP_TARGET"
printf 'Open it from Applications. If macOS asks you to confirm, see https://github.com/neokumar1/Isolate#first-launch\n'
