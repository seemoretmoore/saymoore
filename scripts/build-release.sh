#!/usr/bin/env bash
# Build a Release-configuration archive of SayMoore, export it, zip the .app,
# and EdDSA-sign the zip using the private key stored in the login Keychain
# under account "SayMoore".
#
# Outputs under release/<version>/:
#   SayMoore-<version>.zip          — zipped .app bundle
#   SayMoore-<version>.sig          — base64 EdDSA signature (single line)
#   SayMoore-<version>.length       — byte length of the zip

set -euo pipefail

cd "$(dirname "$0")/.."

if [[ ! -d SayMoore.xcodeproj ]]; then
    bash scripts/generate-project.sh
fi

# Single source of truth: project.yml.
VERSION=$(awk -F': ' '/^    MARKETING_VERSION:/{gsub(/"/,"",$2); print $2; exit}' project.yml)
BUILD=$(awk -F': ' '/^    CURRENT_PROJECT_VERSION:/{gsub(/"/,"",$2); print $2; exit}' project.yml)
if [[ -z "$VERSION" || -z "$BUILD" ]]; then
    echo "error: could not parse MARKETING_VERSION / CURRENT_PROJECT_VERSION from project.yml" >&2
    exit 1
fi

OUT="release/$VERSION"
mkdir -p "$OUT"
ARCHIVE="build/SayMoore-$VERSION.xcarchive"
EXPORT_DIR="build/export-$VERSION"
rm -rf "$ARCHIVE" "$EXPORT_DIR"

xcodebuild \
    -project SayMoore.xcodeproj \
    -scheme SayMoore \
    -configuration Release \
    -derivedDataPath build/ \
    -archivePath "$ARCHIVE" \
    CODE_SIGN_IDENTITY="SayMoore Self-Sign" \
    CODE_SIGN_STYLE=Manual \
    archive

cat > "build/exportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>mac-application</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>SayMoore Self-Sign</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "build/exportOptions.plist"

APP="$EXPORT_DIR/SayMoore.app"
[[ -d "$APP" ]] || { echo "error: $APP missing after export" >&2; exit 1; }

if codesign -dvv "$APP" 2>&1 | grep -qE 'flags=0x2\(adhoc\)|Signature=adhoc'; then
    echo "error: exported app is ad-hoc signed; run scripts/setup-signing.sh" >&2
    exit 1
fi

ZIP="$OUT/SayMoore-$VERSION.zip"
( cd "$EXPORT_DIR" && /usr/bin/ditto -c -k --keepParent SayMoore.app "../../$ZIP" )

SIGN_UPDATE="build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
[[ -x "$SIGN_UPDATE" ]] || { echo "error: $SIGN_UPDATE not found" >&2; exit 1; }

# sign_update auto-reads the private key from Keychain by --account.
SIG_LINE=$("$SIGN_UPDATE" --account SayMoore "$ZIP")
echo "$SIG_LINE" | sed -E 's/.*sparkle:edSignature="([^"]+)".*/\1/' > "$OUT/SayMoore-$VERSION.sig"
stat -f%z "$ZIP" > "$OUT/SayMoore-$VERSION.length"

echo
echo "✓ Built and signed:"
echo "    $ZIP"
echo "    signature: $(cat "$OUT/SayMoore-$VERSION.sig")"
echo "    length:    $(cat "$OUT/SayMoore-$VERSION.length") bytes"
echo "    version:   $VERSION (build $BUILD)"
