#!/bin/bash
# Prints the public notes for a release tag: what to download, the first-launch
# steps for the ad-hoc-signed build, and that version's CHANGELOG.md section.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${1:?Usage: scripts/release_notes.sh v1.3.0}"
VERSION="${TAG#v}"
[[ -f "$PROJECT_DIR/CHANGELOG.md" ]] || { echo "CHANGELOG.md is missing." >&2; exit 1; }
CHANGES=$(awk -v heading="## [${VERSION}]" '
    /^## / { if (found) exit; if (index($0, heading) == 1) { found = 1; next } }
    found { print }
' "$PROJECT_DIR/CHANGELOG.md")
if [[ -z "${CHANGES//[[:space:]]/}" ]]; then
    echo "CHANGELOG.md has no '## [${VERSION}]' section." >&2
    exit 1
fi

cat <<EOF
Isolate splits songs into vocals, drums, bass and other on your Mac, then lets you mix, loop and export them. Requires a Mac with Apple silicon and macOS 14 Sonoma or later; macOS 26 or later is recommended, because Core ML in macOS 14 and 15 computes the separation model incorrectly on some compute paths. Isolate checks this before separating and asks you to update if needed. The separation model is included, and nothing is uploaded.

## Download

- **Isolate.dmg** (recommended): open it and drag Isolate into Applications.
- Isolate-${TAG}-macOS.zip: the same app in a ZIP.
- SHA256SUMS.txt: checksums for both files.

## First launch

This build is ad-hoc signed and not notarized by Apple, so macOS asks you to approve it once.

- **macOS 15 or later:** open Isolate and click **Done** when macOS says it could not verify it. Go to **System Settings › Privacy & Security**, scroll to **Security**, click **Open Anyway** next to the Isolate message, authenticate, then click **Open**.
- **macOS 14:** Control-click Isolate in Applications, choose **Open**, then click **Open**.

Please don't turn off Gatekeeper or clear quarantine attributes to skip this. More help: [First launch](https://github.com/neokumar1/Isolate#first-launch) and [Troubleshooting](https://github.com/neokumar1/Isolate/blob/${TAG}/TROUBLESHOOTING.md).

## What's changed
${CHANGES}
EOF
