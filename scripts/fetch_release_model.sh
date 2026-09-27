#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${ISOLATE_MODEL_ARCHIVE_URL:?Configure the pinned model URL; see MODEL.md}"
: "${ISOLATE_MODEL_ARCHIVE_SHA256:?Configure the pinned model checksum; see MODEL.md}"
[[ "$ISOLATE_MODEL_ARCHIVE_URL" == https://* ]] || { echo "Model URL must use HTTPS." >&2; exit 1; }
# shasum prints lowercase hex, so accept a checksum pasted in either case.
EXPECTED=$(printf '%s' "$ISOLATE_MODEL_ARCHIVE_SHA256" | tr 'A-F' 'a-f')
[[ "$EXPECTED" =~ ^[a-f0-9]{64}$ ]] || { echo "Invalid model SHA-256." >&2; exit 1; }
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/isolate-model.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT
curl --proto '=https' --tlsv1.2 -fL --retry 3 "$ISOLATE_MODEL_ARCHIVE_URL" -o "$WORK_DIR/model.zip"
ACTUAL=$(shasum -a 256 "$WORK_DIR/model.zip" | awk '{print $1}')
[[ "$ACTUAL" == "$EXPECTED" ]] || { echo "Model archive checksum mismatch: expected ${EXPECTED}, got ${ACTUAL}." >&2; exit 1; }
ditto -x -k "$WORK_DIR/model.zip" "$WORK_DIR/unpacked"
swift scripts/validate_model.swift "$WORK_DIR/unpacked/HTDemucs.mlmodelc"
MODEL_DESTINATION="${ISOLATE_MODEL_DESTINATION:-$HOME/Library/Application Support/Isolate/HTDemucs.mlmodelc}"
[[ ! -e "$MODEL_DESTINATION" ]] || { echo "Model already exists; refusing to overwrite it." >&2; exit 1; }
mkdir -p "$(dirname "$MODEL_DESTINATION")"
ditto "$WORK_DIR/unpacked/HTDemucs.mlmodelc" "$MODEL_DESTINATION"
echo "Installed the validated model at ${MODEL_DESTINATION}."
