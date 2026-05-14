#!/usr/bin/env bash
# Copy the freshly-built Debug SayMoore.app from DerivedData to ~/Applications,
# so macOS TCC grants can target a stable application location instead of a
# build-product cache. Run after every Debug build before relaunching.
set -euo pipefail

DERIVED=$(find "$HOME/Library/Developer/Xcode/DerivedData" -name SayMoore.app -path '*Debug/*' -print -quit)
if [ -z "$DERIVED" ] || [ ! -d "$DERIVED" ]; then
    echo "error: no Debug SayMoore.app found under DerivedData. Build first." >&2
    exit 1
fi

DEST="$HOME/Applications/SayMoore.app"
mkdir -p "$HOME/Applications"
[ -d "$DEST" ] && rm -rf "$DEST"
cp -R "$DERIVED" "$DEST"

LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister
[ -x "$LSREG" ] && "$LSREG" -f "$DEST"

echo "Source:    $DERIVED"
echo "Installed: $DEST"
codesign -dvv "$DEST" 2>&1 | grep -E 'Authority|flags|Identifier' >&2
