#!/bin/bash
# Prints the app version from project.yml, the source of truth, after checking
# that the checked-in Info.plist agrees. Given a tag, also requires v<version>.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
fail() {
    if [[ "${GITHUB_ACTIONS:-}" == true ]]; then echo "::error::$1"; else echo "$1" >&2; fi
    exit 1
}
project_value() {
    sed -nE "s/^[[:space:]]*$1:[[:space:]]*\"?([^\"[:space:]]+)\"?[[:space:]]*$/\1/p" "$PROJECT_DIR/project.yml" | head -n 1
}
plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$PROJECT_DIR/Info.plist" 2>/dev/null || true
}

VERSION=$(project_value CFBundleShortVersionString)
BUILD=$(project_value CFBundleVersion)
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "project.yml CFBundleShortVersionString must look like 1.3.0; found '${VERSION}'."
[[ -n "$BUILD" ]] || fail "project.yml has no CFBundleVersion."
PLIST_VERSION=$(plist_value CFBundleShortVersionString)
PLIST_BUILD=$(plist_value CFBundleVersion)
if [[ "$PLIST_VERSION" != "$VERSION" || "$PLIST_BUILD" != "$BUILD" ]]; then
    fail "Info.plist says ${PLIST_VERSION:-nothing} (${PLIST_BUILD:-nothing}) but project.yml says ${VERSION} (${BUILD}). Run xcodegen generate and commit Info.plist."
fi
if [[ $# -gt 0 && "$1" != "v${VERSION}" ]]; then
    fail "Release tag $1 does not match app version ${VERSION} in project.yml. Tag v${VERSION}, or update project.yml and regenerate first."
fi
printf '%s\n' "$VERSION"
