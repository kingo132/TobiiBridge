#!/bin/bash
set -euo pipefail

BRIDGE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$BRIDGE/.." && pwd)"
NATIVE="$BRIDGE/native"
SRC="$BRIDGE/TobiiBridge.swift"
ICON="$BRIDGE/assets/AppIcon-1024.png"
APP="$HOME/Applications/TobiiBridge-Native-v1.5.app"
LIBUSB="$(brew --prefix libusb)"

[ -f "$REPO/driver/src/tobiifree_core.zig" ] || { echo "Missing $REPO/driver/src/tobiifree_core.zig"; exit 1; }
[ -f "$REPO/driver/src/tlv.zig" ] || { echo "Missing $REPO/driver/src/tlv.zig"; exit 1; }
[ -f "$SRC" ] || { echo "Missing $SRC"; exit 1; }
[ -f "$ICON" ] || { echo "Missing $ICON"; exit 1; }
[ ! -e "$APP" ] || { echo "Refusing to overwrite existing $APP"; exit 1; }

"$NATIVE/sync-core-from-upstream.sh"

BUILD="$(mktemp -d "${TMPDIR:-/tmp/}tobiibridge-v15.XXXXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
OUT="$BUILD/libtobii_native.a"

echo "===== Zig static library ====="
zig build-lib -O ReleaseFast -lc \
  -I "$LIBUSB/include/libusb-1.0" \
  -femit-bin="$OUT" "$NATIVE/tobii_native.zig"

echo "===== Swift AppKit + IOKit ====="
swiftc -O \
  -framework AppKit \
  -framework IOKit \
  -I "$NATIVE" \
  -L "$LIBUSB/lib" \
  -Xlinker -rpath \
  -Xlinker '@executable_path/../Frameworks' \
  "$SRC" "$OUT" -lusb-1.0 \
  -o "$BUILD/TobiiBridge"

echo "===== App icon ====="
ICONSET="$BUILD/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -s format png -z "$size" "$size" "$ICON" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  retina=$((size * 2))
  sips -s format png -z "$retina" "$retina" "$ICON" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$BUILD/AppIcon.icns"

echo "===== App bundle ====="
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BUILD/TobiiBridge" "$APP/Contents/MacOS/TobiiBridge"
cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp -L "$LIBUSB/lib/libusb-1.0.0.dylib" "$APP/Contents/Frameworks/libusb-1.0.0.dylib"
chmod u+w "$APP/Contents/Frameworks/libusb-1.0.0.dylib"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>English</string>
<key>CFBundleExecutable</key><string>TobiiBridge</string>
<key>CFBundleIdentifier</key><string>local.tobiibridge.native.v15</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleName</key><string>TobiiBridge</string>
<key>CFBundleDisplayName</key><string>TobiiBridge</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.5.0</string>
<key>CFBundleVersion</key><string>15</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST

install_name_tool -id '@rpath/libusb-1.0.0.dylib' "$APP/Contents/Frameworks/libusb-1.0.0.dylib"
LIBUSB_LINK="$(otool -L "$APP/Contents/MacOS/TobiiBridge" | awk '/libusb-1\.0.*\.dylib/ {print $1; exit}')"
[ -n "$LIBUSB_LINK" ] || { echo "Could not locate libusb load command"; exit 1; }
install_name_tool -change "$LIBUSB_LINK" '@rpath/libusb-1.0.0.dylib' "$APP/Contents/MacOS/TobiiBridge"

codesign --force --sign - "$APP/Contents/Frameworks/libusb-1.0.0.dylib"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
plutil -lint "$APP/Contents/Info.plist"

echo "===== BUILD SUCCESS ====="
echo "$APP"
