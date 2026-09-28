#!/usr/bin/env bash
# 构建 Claude Usage Monitor.app：release 编译 → 导出图标 → 生成 .icns → 组装 → 签名
# 可选环境变量：VERSION（写入 CFBundleShortVersionString）、BUILD_NUMBER（写入 CFBundleVersion）、CODESIGN_IDENTITY
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Claude Usage Monitor"
EXECUTABLE="ClaudeUsageMonitor"
OUT="$ROOT/build"
APP="$OUT/$APP_NAME.app"

cd "$ROOT"
echo "▸ 编译 (release)"
swift build -c release --product "$EXECUTABLE"
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "▸ 导出图标"
ASSETS="$OUT/assets"
rm -rf "$ASSETS" && mkdir -p "$ASSETS"
"$BIN_DIR/$EXECUTABLE" --export-assets "$ASSETS" >/dev/null

ICONSET="$OUT/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ASSETS/AppIcon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$ASSETS/AppIcon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$OUT/AppIcon.icns"

echo "▸ 组装 $APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$OUT/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

if [ -n "${VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
if [ -n "${BUILD_NUMBER:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
fi

# 优先使用本机的开发证书签名：签名标识稳定，钥匙串「始终允许」在重新构建后依然有效
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development|Developer ID Application/ {print $2; exit}')"
fi
if [ -n "$IDENTITY" ]; then
  echo "▸ 签名（开发证书）"
else
  IDENTITY="-"
  echo "▸ 签名（ad-hoc）"
fi
codesign --force --sign "$IDENTITY" --timestamp=none "$APP" >/dev/null

echo "✓ 完成：$APP"
