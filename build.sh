#!/bin/zsh
# Builds "Rota.app" into ./build and installs it to ~/Applications.
set -e
cd "$(dirname "$0")"
swift build -c release
APP="build/Rota.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Rota "$APP/Contents/MacOS/Rota"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Rota</string>
  <key>CFBundleIdentifier</key><string>com.futurefabrik.rota</string>
  <key>CFBundleName</key><string>Rota</string>
  <key>CFBundleDisplayName</key><string>Rota</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Rota asks Pages, Keynote and Numbers to convert your documents.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
if [[ "$1" == "--install" ]]; then
  pkill -x Rota || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/"Rota.app"
  ditto "$APP" ~/Applications/"Rota.app"
  open ~/Applications/"Rota.app"
  echo "Installed and launched ~/Applications/Rota.app"
fi
