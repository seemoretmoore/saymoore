#!/usr/bin/env bash
# Skeleton release build. Slice 11 will extend this with archive + EdDSA + zip.
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ ! -d SayMoore.xcodeproj ]]; then
    echo "SayMoore.xcodeproj not found — running generate-project.sh first."
    bash scripts/generate-project.sh
fi

xcodebuild \
    -project SayMoore.xcodeproj \
    -scheme SayMoore \
    -configuration Release \
    -derivedDataPath build/ \
    CODE_SIGN_IDENTITY="SayMoore Self-Sign" \
    CODE_SIGN_STYLE=Manual \
    build

APP="build/Build/Products/Release/SayMoore.app"
if [[ -d "$APP" ]]; then
    echo "✓ Built $APP"
fi
