#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="法典笔记"
VERSION="3.8"
BUNDLE_ID="cn.fadian.notes"
APP="build/${APP_NAME}.app"
DMG="dist/法典笔记-${VERSION}-macOS.dmg"
PKG="dist/法典笔记-${VERSION}-macOS.pkg"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
DEPLOYMENT="13.0"

echo "==> 编译通用二进制"
mkdir -p build/arm64 build/x86_64
for ARCH in arm64 x86_64; do
  echo "    $ARCH"
  swiftc -swift-version 5 -O \
    -target "${ARCH}-apple-macos${DEPLOYMENT}" \
    -sdk "$SDK" \
    -framework Cocoa -framework WebKit \
    Sources/main.swift \
    -o "build/${ARCH}/FadianNotes" 2> "build/compile-${ARCH}.log" || {
      cat "build/compile-${ARCH}.log"; exit 1;
    }
done
lipo -create build/arm64/FadianNotes build/x86_64/FadianNotes -output build/FadianNotes

echo "==> 清理扩展属性"
xattr -cr Resources/web 2>/dev/null || true

echo "==> 组装 App"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/web"
cp build/FadianNotes "$APP/Contents/MacOS/FadianNotes"
cp Info.plist "$APP/Contents/Info.plist"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/web/* "$APP/Contents/Resources/web/"
printf 'APPL????' > "$APP/Contents/PkgInfo"
chmod +x "$APP/Contents/MacOS/FadianNotes"
xattr -cr "$APP" 2>/dev/null || true

echo "==> 签名（ad-hoc）"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1
codesign --verify --deep --strict "$APP"

echo "==> 生成 DMG"
rm -rf build/dmg-root
mkdir -p build/dmg-root dist
ditto "$APP" "build/dmg-root/${APP_NAME}.app"
ln -s /Applications "build/dmg-root/Applications"
cp "安装说明.txt" "build/dmg-root/安装说明.txt"
rm -f "$DMG"
hdiutil create \
  -volname "${APP_NAME} ${VERSION}" \
  -srcfolder build/dmg-root \
  -ov -format UDZO \
  "$DMG" >/dev/null

echo "==> 生成 PKG"
rm -f "$PKG"
pkgbuild \
  --component "$APP" \
  --install-location /Applications \
  --identifier "${BUNDLE_ID}.pkg" \
  --version "$VERSION" \
  "$PKG" >/dev/null

echo "==> 校验"
echo "    App:"
file "$APP/Contents/MacOS/FadianNotes"
echo "    DMG:"
hdiutil imageinfo "$DMG" | grep -E 'Format Description|Total Bytes' | sed 's/^/      /'
echo "    PKG:"
pkgutil --payload-files "$PKG" | sed 's/^/      /' | head -8

echo
echo "完成："
ls -lh "$DMG" "$PKG"
