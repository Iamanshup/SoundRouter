#!/bin/zsh
# Builds SoundRouter.app and installs it into ~/Applications.
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/SoundRouter.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SoundRouter "$APP/Contents/MacOS/SoundRouter"
cp -R BrowserExtension "$APP/Contents/Resources/BrowserExtension"
cp Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.soundrouter.app</string>
  <key>CFBundleName</key><string>SoundRouter</string>
  <key>CFBundleDisplayName</key><string>SoundRouter</string>
  <key>CFBundleExecutable</key><string>SoundRouter</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAudioCaptureUsageDescription</key><string>SoundRouter captures each app's audio so it can play it on the speaker you choose.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
mkdir -p ~/Applications
rm -rf ~/Applications/SoundRouter.app
cp -R "$APP" ~/Applications/
echo "Installed ~/Applications/SoundRouter.app"
