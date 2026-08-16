#!/bin/bash
# Build a compressed macOS DMG containing Dropship.app and an Applications link.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP_NAME="Dropship"
APP_DIR="$ROOT/build/$APP_NAME.app"
EXECUTABLE="$APP_DIR/Contents/MacOS/$APP_NAME"
OUTPUT_DIR="$ROOT/dist"

"$ROOT/scripts/build-app.sh" release

if [[ ! -d "$APP_DIR" || ! -f "$EXECUTABLE" ]]; then
    echo "error: missing app bundle at $APP_DIR" >&2
    exit 1
fi

/usr/bin/codesign --verify --deep --strict "$APP_DIR"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")"
APP_ARCH="$(/usr/bin/lipo -archs "$EXECUTABLE" | /usr/bin/tr ' ' '-')"
ARTIFACT_NAME="$APP_NAME-v$VERSION-macos-$APP_ARCH.dmg"
DMG_PATH="$OUTPUT_DIR/$ARTIFACT_NAME"
CHECKSUM_PATH="$DMG_PATH.sha256"
VOLUME_NAME="$APP_NAME $VERSION"

STAGING_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/dropship-dmg.XXXXXX")"
cleanup() {
    if [[ -n "${STAGING_DIR:-}" && -d "$STAGING_DIR" ]]; then
        /bin/rm -rf -- "$STAGING_DIR"
    fi
}
trap cleanup EXIT

/bin/mkdir -p "$OUTPUT_DIR"
/usr/bin/ditto "$APP_DIR" "$STAGING_DIR/$APP_NAME.app"
/bin/ln -s /Applications "$STAGING_DIR/Applications"

echo "==> Creating $ARTIFACT_NAME"
/usr/bin/hdiutil create \
    -volname "$VOLUME_NAME" \
    -fs HFS+ \
    -srcfolder "$STAGING_DIR" \
    -format UDZO \
    -ov \
    "$DMG_PATH"

/usr/bin/hdiutil verify "$DMG_PATH"
(
    cd "$OUTPUT_DIR"
    /usr/bin/shasum -a 256 "$ARTIFACT_NAME" > "$ARTIFACT_NAME.sha256"
)

echo "==> DMG: $DMG_PATH"
echo "==> SHA-256: $CHECKSUM_PATH"
