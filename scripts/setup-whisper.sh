#!/usr/bin/env bash
# Build whisper.cpp into a macOS XCFramework that SayMoore links in-process.
#
# Background: whisper.cpp removed Package.swift upstream (see docs/spikes/whisper-spm.md);
# the project now ships in-process integration via build-xcframework.sh. This script
# pins a tag, runs that build, and drops the resulting Vendor/whisper.xcframework into
# the repo (gitignored — ~200 MB).
#
# Usage:
#   bash scripts/setup-whisper.sh                # idempotent: skips if version stamp matches
#   bash scripts/setup-whisper.sh --force-rebuild

set -euo pipefail

WHISPER_TAG="v1.7.6"
WHISPER_REPO="https://github.com/ggml-org/whisper.cpp"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build/whisper-build"
VENDOR_DIR="${ROOT_DIR}/Vendor"
FRAMEWORK_DST="${VENDOR_DIR}/whisper.xcframework"
STAMP_FILE="${VENDOR_DIR}/.whisper-version"

FORCE=0
for arg in "$@"; do
    case "$arg" in
        --force-rebuild) FORCE=1 ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "Unknown flag: $arg" >&2; exit 2 ;;
    esac
done

if [[ -d "$FRAMEWORK_DST" && -f "$STAMP_FILE" && "$FORCE" -eq 0 ]]; then
    if [[ "$(cat "$STAMP_FILE")" == "$WHISPER_TAG" ]]; then
        echo "✓ Vendor/whisper.xcframework is already at $WHISPER_TAG — leaving alone."
        echo "  (Pass --force-rebuild to rebuild from scratch.)"
        exit 0
    fi
fi

if ! command -v cmake >/dev/null 2>&1; then
    echo "✗ cmake is required. Install with: brew install cmake" >&2
    exit 3
fi
if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "✗ xcodebuild not found — Xcode command line tools required." >&2
    exit 3
fi

mkdir -p "$VENDOR_DIR"
mkdir -p "$(dirname "$BUILD_DIR")"

if [[ ! -d "$BUILD_DIR/.git" ]]; then
    echo "Cloning $WHISPER_REPO @ $WHISPER_TAG into ${BUILD_DIR}…"
    rm -rf "$BUILD_DIR"
    git clone --depth 1 --branch "$WHISPER_TAG" "$WHISPER_REPO" "$BUILD_DIR"
else
    echo "Reusing existing clone at $BUILD_DIR (run with --force-rebuild to wipe)."
    (cd "$BUILD_DIR" && git fetch --depth 1 origin tag "$WHISPER_TAG" >/dev/null 2>&1 || true)
    (cd "$BUILD_DIR" && git checkout "$WHISPER_TAG")
fi

if [[ ! -x "$BUILD_DIR/build-xcframework.sh" ]]; then
    echo "✗ $BUILD_DIR/build-xcframework.sh missing/non-executable — repo layout changed?" >&2
    exit 4
fi

echo "Running build-xcframework.sh (this takes a few minutes)…"
(
    cd "$BUILD_DIR"
    bash build-xcframework.sh
)

# build-xcframework.sh emits build-apple/whisper.xcframework. Path may vary slightly
# across versions; locate it explicitly so we fail loud if upstream moves it.
SRC_FRAMEWORK="$(find "$BUILD_DIR" -name whisper.xcframework -type d -maxdepth 4 | head -1)"
if [[ -z "$SRC_FRAMEWORK" ]]; then
    echo "✗ Could not find whisper.xcframework after build." >&2
    exit 5
fi

echo "Installing → $FRAMEWORK_DST"
rm -rf "$FRAMEWORK_DST"
cp -R "$SRC_FRAMEWORK" "$FRAMEWORK_DST"
echo "$WHISPER_TAG" > "$STAMP_FILE"

echo
echo "✓ whisper.xcframework installed at $WHISPER_TAG"
echo "  Now regenerate the project: bash scripts/generate-project.sh"
