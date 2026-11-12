#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_PATH="$PROJECT_DIR/outputs/The Intelligent Cursor.app"
CONTENTS_PATH="$APP_PATH/Contents"
MACOS_PATH="$CONTENTS_PATH/MacOS"
RESOURCES_PATH="$CONTENTS_PATH/Resources"

BUILD_PATH="$PROJECT_DIR/work/build"
BIN_PATH="$BUILD_PATH/IntelligentCursor"
MODULE_CACHE_PATH="$PROJECT_DIR/work/module-cache"
TOOLCHAIN_FIX_PATH="$PROJECT_DIR/work/toolchain-fix"
mkdir -p "$BUILD_PATH" "$MODULE_CACHE_PATH" "$TOOLCHAIN_FIX_PATH"

EXTRA_FLAGS=()

# Some Command Line Tools installs keep a stale pre-2024 module.modulemap next to
# the current bridging.modulemap. Both declare module SwiftBridging, so every SDK
# .swiftinterface fails to build and the compiler appears to hang instead of
# reporting anything. A VFS overlay blanks the stale copy for this build only;
# nothing outside work/ is touched.
STALE_MODULEMAP="$(dirname "$(dirname "$(xcrun --find swiftc)")")/include/swift/module.modulemap"
BRIDGING_MODULEMAP="$(dirname "$STALE_MODULEMAP")/bridging.modulemap"
if [[ -f "$STALE_MODULEMAP" && -f "$BRIDGING_MODULEMAP" ]] &&
   grep -q "module SwiftBridging" "$STALE_MODULEMAP" &&
   grep -q "module SwiftBridging" "$BRIDGING_MODULEMAP"; then
    : > "$TOOLCHAIN_FIX_PATH/empty.modulemap"
    cat > "$TOOLCHAIN_FIX_PATH/overlay.yaml" <<OVERLAY
{
  "version": 0,
  "case-sensitive": false,
  "roots": [
    {
      "type": "file",
      "name": "$STALE_MODULEMAP",
      "external-contents": "$TOOLCHAIN_FIX_PATH/empty.modulemap"
    }
  ]
}
OVERLAY
    EXTRA_FLAGS+=(-Xfrontend -vfsoverlay -Xfrontend "$TOOLCHAIN_FIX_PATH/overlay.yaml")
    echo "note: neutralising duplicate SwiftBridging module map at $STALE_MODULEMAP"
fi

SOURCE_FILES=()
while IFS= read -r source_file; do
    SOURCE_FILES+=("$source_file")
done < <(find "$PROJECT_DIR/Sources/IntelligentCursor" -name '*.swift' -type f | sort)

swiftc \
    -swift-version 5 \
    -target arm64-apple-macosx15.2 \
    -parse-as-library \
    -O \
    -module-cache-path "$MODULE_CACHE_PATH" \
    "${EXTRA_FLAGS[@]}" \
    "${SOURCE_FILES[@]}" \
    -framework AppKit \
    -framework ApplicationServices \
    -framework AVFoundation \
    -framework Carbon \
    -framework CoreGraphics \
    -framework PDFKit \
    -framework ScreenCaptureKit \
    -framework Security \
    -framework Speech \
    -framework SwiftUI \
    -framework UniformTypeIdentifiers \
    -framework Vision \
    -o "$BIN_PATH"

if [[ -e "$APP_PATH" ]]; then
    rm -rf "$APP_PATH"
fi

mkdir -p "$MACOS_PATH" "$RESOURCES_PATH"
cp "$BIN_PATH" "$MACOS_PATH/IntelligentCursor"
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_PATH/Info.plist"

# Prefer the stable local identity from scripts/setup-signing.sh. An ad-hoc
# signature's designated requirement is a bare cdhash, so every rebuild would
# revoke the app's Accessibility, Input Monitoring, and Screen Recording grants.
DEV_KEYCHAIN="$HOME/Library/Keychains/intelligent-cursor-dev.keychain-db"
DEV_IDENTITY="Intelligent Cursor Dev"
PASSWORD_FILE="$HOME/.intelligent-cursor/signing/keychain-password"

# The project lives on an iCloud-synced Desktop, which stamps com.apple.FinderInfo
# on the bundle; codesign refuses to sign anything carrying it. The recursive pass
# misses the bundle root, so clear that explicitly too.
xattr -cr "$APP_PATH" 2>/dev/null || true
xattr -c "$APP_PATH" 2>/dev/null || true

if [[ -f "$DEV_KEYCHAIN" && -f "$PASSWORD_FILE" ]]; then
    security unlock-keychain -p "$(cat "$PASSWORD_FILE")" "$DEV_KEYCHAIN"
    codesign --force --sign "$DEV_IDENTITY" --keychain "$DEV_KEYCHAIN" \
        --identifier com.caeseyfraser.intelligent-cursor "$APP_PATH"
else
    echo "note: signing ad-hoc; run scripts/setup-signing.sh so permissions survive rebuilds"
    codesign --force --sign - --identifier com.caeseyfraser.intelligent-cursor "$APP_PATH"
fi

echo "$APP_PATH"
