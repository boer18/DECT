#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
APP_DIR="$SCRIPT_DIR/dist/表格工具.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICONSET_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/one-click-table-export-icon.XXXXXX")"
ICONSET_DIR="$ICONSET_ROOT/AppIcon.iconset"
RENDER_DIR="$(mktemp -d "${TMPDIR:-/tmp}/one-click-table-export-render.XXXXXX")"
RENDERED_ICON="$RENDER_DIR/AppIcon.svg.png"

cleanup() {
  rm -rf "$ICONSET_ROOT"
  rm -rf "$RENDER_DIR"
}
trap cleanup EXIT

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$ICONSET_DIR"

/usr/bin/xcrun swiftc \
  -target arm64-apple-macos14.0 \
  -parse-as-library \
  -O \
  -framework AppKit \
  -framework SwiftUI \
  "$SCRIPT_DIR"/Sources/*.swift \
  -o "$MACOS_DIR/OneClickTableExport"

/bin/cp "$SCRIPT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
/usr/bin/xcrun swift "$SCRIPT_DIR/Tools/render-icon.swift" "$RENDERED_ICON"
/bin/cp "$RENDERED_ICON" "$RESOURCES_DIR/AppIcon.png"
/usr/bin/sips -z 16 16 "$RENDERED_ICON" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
/usr/bin/sips -z 32 32 "$RENDERED_ICON" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
/usr/bin/sips -z 32 32 "$RENDERED_ICON" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
/usr/bin/sips -z 64 64 "$RENDERED_ICON" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
/usr/bin/sips -z 128 128 "$RENDERED_ICON" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
/usr/bin/sips -z 256 256 "$RENDERED_ICON" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
/usr/bin/sips -z 256 256 "$RENDERED_ICON" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
/usr/bin/sips -z 512 512 "$RENDERED_ICON" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
/usr/bin/sips -z 512 512 "$RENDERED_ICON" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
/usr/bin/sips -z 1024 1024 "$RENDERED_ICON" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null
/usr/bin/iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns"
/usr/bin/codesign --force --sign - --timestamp=none "$APP_DIR"
/usr/bin/xattr -dr com.apple.quarantine "$APP_DIR" 2>/dev/null || true

echo "Built: $APP_DIR"
