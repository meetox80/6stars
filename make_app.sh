#!/bin/zsh
set -e
cd "$(dirname "$0")"
./build.sh --product 6stars
APP="$HOME/testing/6stars.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/6stars "$APP/Contents/MacOS/6stars"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>6stars</string>
  <key>CFBundleIdentifier</key><string>local.testing.6stars</string>
  <key>CFBundleName</key><string>6stars</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "built $APP"
