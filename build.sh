#!/bin/zsh
# Builds "Hot Wheel.app" into ./build and installs it to ~/Applications.
set -e
cd "$(dirname "$0")"
swift build -c release
APP="build/Hot Wheel.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/FileWheel "$APP/Contents/MacOS/FileWheel"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>FileWheel</string>
  <key>CFBundleIdentifier</key><string>com.futurefabrik.filewheel</string>
  <key>CFBundleName</key><string>Hot Wheel</string>
  <key>CFBundleDisplayName</key><string>Hot Wheel</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Hot Wheel asks Pages, Keynote and Numbers to convert your documents.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
if [[ "$1" == "--install" ]]; then
  pkill -x FileWheel || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/"Hot Wheel.app"
  ditto "$APP" ~/Applications/"Hot Wheel.app"
  open ~/Applications/"Hot Wheel.app"
  echo "Installed and launched ~/Applications/Hot Wheel.app"
fi
