#!/bin/zsh
# Builds SoundRouter.app and installs it into ~/Applications.
#   UNIVERSAL=1  build for both Apple Silicon and Intel
#   INSTALL=0    only build build/SoundRouter.app, don't install it
set -e
cd "$(dirname "$0")"
VERSION=1.1
APP=build/SoundRouter.app

if [[ "$UNIVERSAL" == 1 ]]; then
  # Separate scratch paths so the two builds don't overwrite each other.
  for arch in arm64 x86_64; do
    swift build -c release --triple $arch-apple-macosx15.0 --scratch-path .build/$arch
  done
  BIN=build/SoundRouter-universal
  mkdir -p build
  lipo -create -output $BIN \
    "$(swift build -c release --triple arm64-apple-macosx15.0 --scratch-path .build/arm64 --show-bin-path)/SoundRouter" \
    "$(swift build -c release --triple x86_64-apple-macosx15.0 --scratch-path .build/x86_64 --show-bin-path)/SoundRouter"
else
  swift build -c release
  BIN="$(swift build -c release --show-bin-path)/SoundRouter"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SoundRouter"
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
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAudioCaptureUsageDescription</key><string>SoundRouter captures each app's audio so it can play it on the speaker you choose.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
[[ "$INSTALL" == 0 ]] && { echo "Built $APP"; exit 0; }
mkdir -p ~/Applications
rm -rf ~/Applications/SoundRouter.app
cp -R "$APP" ~/Applications/
echo "Installed ~/Applications/SoundRouter.app"
