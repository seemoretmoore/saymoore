#!/usr/bin/env bash
# Vendor the Silero VAD v5 ONNX model that SayMoore uses for voice-activity
# detection (Slice 5). The model is fetched from a pinned release tag, placed
# at Vendor/silero-vad/silero_vad.onnx, and checksummed against a known hash.
#
# The actual ONNX Runtime library is pulled via SwiftPM (see project.yml) —
# this script handles only the model weights.
#
# Usage:
#   bash scripts/setup-silero.sh                # idempotent: skips if hash matches
#   bash scripts/setup-silero.sh --force-redownload

set -euo pipefail

SILERO_TAG="v5.1.2"
SILERO_URL="https://raw.githubusercontent.com/snakers4/silero-vad/${SILERO_TAG}/src/silero_vad/data/silero_vad.onnx"
SILERO_SHA256="2623a2953f6ff3d2c1e61740c6cdb7168133479b267dfef114a4a3cc5bdd788f"

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="${ROOT_DIR}/Vendor/silero-vad"
MODEL_DST="${VENDOR_DIR}/silero_vad.onnx"
STAMP_FILE="${VENDOR_DIR}/.silero-version"

FORCE=0
for arg in "$@"; do
    case "$arg" in
        --force-redownload) FORCE=1 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "Unknown flag: $arg" >&2; exit 2 ;;
    esac
done

verify_hash() {
    local file="$1"
    local expected="$2"
    local actual
    actual="$(shasum -a 256 "$file" | awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
        echo "✗ SHA-256 mismatch for $file" >&2
        echo "  expected: $expected" >&2
        echo "  actual:   $actual" >&2
        return 1
    fi
}

if [[ -f "$MODEL_DST" && -f "$STAMP_FILE" && "$FORCE" -eq 0 ]]; then
    if [[ "$(cat "$STAMP_FILE")" == "$SILERO_TAG" ]] && verify_hash "$MODEL_DST" "$SILERO_SHA256" 2>/dev/null; then
        echo "✓ Vendor/silero-vad/silero_vad.onnx is already at $SILERO_TAG — leaving alone."
        echo "  (Pass --force-redownload to refetch.)"
        exit 0
    fi
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "✗ curl is required." >&2
    exit 3
fi

mkdir -p "$VENDOR_DIR"

echo "Downloading $SILERO_URL → $MODEL_DST"
TMP_DST="${MODEL_DST}.tmp"
trap 'rm -f "$TMP_DST"' EXIT
curl -sSL --fail "$SILERO_URL" -o "$TMP_DST"

echo "Verifying SHA-256…"
verify_hash "$TMP_DST" "$SILERO_SHA256"

mv "$TMP_DST" "$MODEL_DST"
echo "$SILERO_TAG" > "$STAMP_FILE"
trap - EXIT

# Also stage into SayMoore/Resources so XcodeGen's resource glob picks it up
# and Xcode bundles it into SayMoore.app/Contents/Resources. The Resources copy
# is gitignored; the canonical copy lives under Vendor/.
RESOURCE_DST="${ROOT_DIR}/SayMoore/Resources/silero_vad.onnx"
mkdir -p "$(dirname "$RESOURCE_DST")"
cp "$MODEL_DST" "$RESOURCE_DST"

echo
echo "✓ silero_vad.onnx installed at $SILERO_TAG ($(wc -c < "$MODEL_DST") bytes)"
echo "  Vendor copy: $MODEL_DST"
echo "  Bundled copy: $RESOURCE_DST"
echo "  Now regenerate the project: bash scripts/generate-project.sh"
