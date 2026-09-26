#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
# Compare the tag with project.yml before any build work; xcodegen rewrites Info.plist from it.
VERSION="${1:-}"
APP_VERSION=$(bash scripts/check_version.sh ${VERSION:+"$VERSION"})
VERSION="${VERSION:-v${APP_VERSION}}"
MODEL_SOURCE="${ISOLATE_MODEL_PATH:-$HOME/Library/Application Support/Isolate/HTDemucs.mlmodelc}"
if [[ ! -d "$MODEL_SOURCE" ]]; then
    echo "Set ISOLATE_MODEL_PATH to the validated HTDemucs.mlmodelc directory. Releases must include the model." >&2
    exit 1
fi
swift scripts/validate_model.swift "$MODEL_SOURCE"

DIST_DIR="${ISOLATE_DIST_DIR:-$PROJECT_DIR/dist}"
mkdir -p "$DIST_DIR"
DIST_DIR="$(cd "$DIST_DIR" && pwd)"
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/isolate-release.XXXXXX")
BUILD_DIR="$WORK_DIR/products"
STAGING_DIR="$WORK_DIR/staging"
MOUNT_DIR="$WORK_DIR/mount"
cleanup() {
    hdiutil detach "$MOUNT_DIR" -quiet 2>/dev/null || true
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT
mkdir -p "$STAGING_DIR" "$MOUNT_DIR"

# hdiutil sometimes reports "Resource busy" on CI runners; a short retry avoids a full rerun.
retry() {
    local attempt
    for attempt in 1 2 3; do
        "$@" && return 0
        echo "$1 failed (attempt ${attempt} of 3)." >&2
        sleep $((attempt * 5))
    done
    return 1
}

xcodegen generate
xcodebuild build -project Isolate.xcodeproj -scheme Isolate -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$WORK_DIR/DerivedData" \
    CONFIGURATION_BUILD_DIR="$BUILD_DIR" CODE_SIGNING_ALLOWED=NO
APP_BUNDLE="$BUILD_DIR/Isolate.app"
BUILT_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")
if [[ "$BUILT_VERSION" != "$APP_VERSION" ]]; then
    echo "The built app reports version ${BUILT_VERSION}, not ${APP_VERSION}." >&2
    exit 1
fi
ditto "$MODEL_SOURCE" "$APP_BUNDLE/Contents/Resources/HTDemucs.mlmodelc"

# Ad-hoc builds also get the hardened runtime, so injected libraries are refused.
SIGNING_IDENTITY="${ISOLATE_SIGNING_IDENTITY:--}"
SIGN_ARGS=(--force --deep --options runtime --sign "$SIGNING_IDENTITY")
if [[ "$SIGNING_IDENTITY" != "-" ]]; then SIGN_ARGS+=(--timestamp); fi
codesign "${SIGN_ARGS[@]}" "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"
if ! codesign -dv "$APP_BUNDLE" 2>&1 | grep -q 'flags=.*runtime'; then
    echo "The app was signed without the hardened runtime." >&2
    exit 1
fi

if [[ -n "${ISOLATE_NOTARY_PROFILE:-}" ]]; then
    [[ "$SIGNING_IDENTITY" != "-" ]] || { echo "Notarization requires Developer ID signing." >&2; exit 1; }
    ditto -c -k --keepParent "$APP_BUNDLE" "$WORK_DIR/notarize.zip"
    xcrun notarytool submit "$WORK_DIR/notarize.zip" --keychain-profile "$ISOLATE_NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP_BUNDLE"
fi

ditto "$APP_BUNDLE" "$STAGING_DIR/Isolate.app"
ln -s /Applications "$STAGING_DIR/Applications"
mkdir -p "$STAGING_DIR/.background"
cp Assets/dmg_background.png "$STAGING_DIR/.background/dmg_background.png"
cp Assets/AppIcon.icns "$STAGING_DIR/.VolumeIcon.icns"
if [[ -f Assets/dmg_ds_store ]]; then cp Assets/dmg_ds_store "$STAGING_DIR/.DS_Store"; fi
# Finder uses .VolumeIcon.icns only when the volume root has the custom-icon flag,
# which -srcfolder cannot set, so build a writable image, flag it, then compress.
retry hdiutil create -ov -srcfolder "$STAGING_DIR" -volname Isolate -fs HFS+ -format UDRW \
    "$WORK_DIR/Isolate-rw.dmg" -quiet
retry hdiutil attach "$WORK_DIR/Isolate-rw.dmg" -nobrowse -noautoopen -noverify \
    -mountpoint "$MOUNT_DIR" -quiet
SetFile -a C "$MOUNT_DIR" || echo "Could not set the volume icon flag; the DMG will show a generic icon." >&2
retry hdiutil detach "$MOUNT_DIR" -quiet
retry hdiutil convert "$WORK_DIR/Isolate-rw.dmg" -ov -format UDZO -o "$WORK_DIR/Isolate.dmg" -quiet
hdiutil verify "$WORK_DIR/Isolate.dmg" -quiet
ditto -c -k --keepParent "$APP_BUNDLE" "$WORK_DIR/Isolate-${VERSION}-macOS.zip"

# Publish only complete artifacts; existing build directories are never erased.
cp "$WORK_DIR/Isolate.dmg" "$DIST_DIR/Isolate.dmg"
cp "$WORK_DIR/Isolate-${VERSION}-macOS.zip" "$DIST_DIR/"
cd "$DIST_DIR"
shasum -a 256 Isolate.dmg "Isolate-${VERSION}-macOS.zip" > SHA256SUMS.txt
printf 'Release artifacts for %s ready in %s\n' "$VERSION" "$DIST_DIR"
printf 'App %s, DMG %s\n' "$(du -sh "$APP_BUNDLE" | cut -f1)" "$(du -h Isolate.dmg | cut -f1)"
