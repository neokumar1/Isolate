#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
APP_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
VERSION="${1:-v${APP_VERSION}}"
if [[ "$VERSION" != "v${APP_VERSION}" ]]; then
    echo "Release tag ${VERSION} does not match app version ${APP_VERSION}. Update project.yml and regenerate first." >&2
    exit 1
fi
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
trap 'rm -rf "$WORK_DIR"' EXIT
BUILD_DIR="$WORK_DIR/products"
STAGING_DIR="$WORK_DIR/staging"
mkdir -p "$STAGING_DIR"

xcodegen generate
xcodebuild build -project Isolate.xcodeproj -scheme Isolate -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$WORK_DIR/DerivedData" \
    CONFIGURATION_BUILD_DIR="$BUILD_DIR" CODE_SIGNING_ALLOWED=NO
APP_BUNDLE="$BUILD_DIR/Isolate.app"
ditto "$MODEL_SOURCE" "$APP_BUNDLE/Contents/Resources/HTDemucs.mlmodelc"

SIGNING_IDENTITY="${ISOLATE_SIGNING_IDENTITY:--}"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    codesign --force --deep --sign - "$APP_BUNDLE"
else
    codesign --force --deep --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
fi
codesign --verify --deep --strict "$APP_BUNDLE"

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
hdiutil create -srcfolder "$STAGING_DIR" -volname Isolate -fs HFS+ -format UDZO \
    "$WORK_DIR/Isolate.dmg" -quiet
hdiutil verify "$WORK_DIR/Isolate.dmg" -quiet
ditto -c -k --keepParent "$APP_BUNDLE" "$WORK_DIR/Isolate-${VERSION}-macOS.zip"

# Publish only complete artifacts; existing build directories are never erased.
cp "$WORK_DIR/Isolate.dmg" "$DIST_DIR/Isolate-${VERSION}.dmg"
cp "$WORK_DIR/Isolate.dmg" "$DIST_DIR/Isolate.dmg"
cp "$WORK_DIR/Isolate-${VERSION}-macOS.zip" "$DIST_DIR/"
cd "$DIST_DIR"
shasum -a 256 Isolate.dmg "Isolate-${VERSION}.dmg" "Isolate-${VERSION}-macOS.zip" > SHA256SUMS.txt
printf 'Release artifacts ready in %s\n' "$DIST_DIR"
