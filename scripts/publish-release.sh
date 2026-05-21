#!/usr/bin/env bash
# Publish the current release: upload the zip to a new versioned GitHub Release,
# regenerate appcast.xml (newest item first, preserving previous items), and
# attach the appcast as a release asset on the rolling "latest" tag.
#
# Requires: gh authenticated against github.com/seemoretmoore/saymoore.

set -euo pipefail

cd "$(dirname "$0")/.."

REPO="seemoretmoore/saymoore"

# Ensure build artifacts exist.
bash scripts/build-release.sh

VERSION=$(awk -F': ' '/^    MARKETING_VERSION:/{gsub(/"/,"",$2); print $2; exit}' project.yml)
BUILD=$(awk -F': ' '/^    CURRENT_PROJECT_VERSION:/{gsub(/"/,"",$2); print $2; exit}' project.yml)
OUT="release/$VERSION"
ZIP="$OUT/SayMoore-$VERSION.zip"
SIG=$(cat "$OUT/SayMoore-$VERSION.sig")
LEN=$(cat "$OUT/SayMoore-$VERSION.length")
TAG="v$VERSION"
ZIP_URL="https://github.com/$REPO/releases/download/$TAG/SayMoore-$VERSION.zip"
PUBDATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")

NEW_ITEM=$(cat <<EOF
<item>
    <title>Version $VERSION</title>
    <pubDate>$PUBDATE</pubDate>
    <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
    <enclosure
        url="$ZIP_URL"
        sparkle:version="$BUILD"
        sparkle:shortVersionString="$VERSION"
        length="$LEN"
        type="application/octet-stream"
        sparkle:edSignature="$SIG" />
</item>
EOF
)

# Pull existing appcast and extract previous <item> blocks (newest first stays
# at top because the new item is prepended).
EXISTING_ITEMS=""
if gh release view latest --repo "$REPO" >/dev/null 2>&1; then
    if gh release download latest --repo "$REPO" -p appcast.xml -O /tmp/appcast.xml.old 2>/dev/null; then
        EXISTING_ITEMS=$(awk '/<item>/,/<\/item>/' /tmp/appcast.xml.old || true)
    fi
fi

ALL_ITEMS="$NEW_ITEM"
if [[ -n "$EXISTING_ITEMS" ]]; then
    ALL_ITEMS="$NEW_ITEM
$EXISTING_ITEMS"
fi

cat > "$OUT/appcast.xml" <<EOF
<?xml version="1.0" standalone="yes"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel>
    <title>SayMoore</title>
    <link>https://github.com/$REPO</link>
    <description>SayMoore release feed.</description>
    <language>en</language>
$ALL_ITEMS
</channel>
</rss>
EOF

# Versioned release.
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    echo "release $TAG already exists; updating zip with --clobber"
    gh release upload "$TAG" "$ZIP" --clobber --repo "$REPO"
else
    gh release create "$TAG" "$ZIP" \
        --repo "$REPO" \
        --title "SayMoore $VERSION" \
        --notes "Automated release."
fi

# Rolling "latest" release: hosts the current appcast.xml.
if ! gh release view latest --repo "$REPO" >/dev/null 2>&1; then
    gh release create latest \
        --repo "$REPO" \
        --title "Latest appcast" \
        --notes "Rolling release that hosts the current appcast.xml. Do not delete."
fi
gh release upload latest "$OUT/appcast.xml" --clobber --repo "$REPO"

echo
echo "✓ Published $VERSION"
echo "    zip: $ZIP_URL"
echo "    appcast: https://github.com/$REPO/releases/latest/download/appcast.xml"
