#!/bin/zsh
# Builds a universal (Apple Silicon + Intel) SoundRouter.app and packages it as dist/SoundRouter-<version>.dmg.
set -e
cd "$(dirname "$0")"
UNIVERSAL=1 INSTALL=0 ./build-app.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/SoundRouter.app/Contents/Info.plist)

STAGE=build/dmg
rm -rf "$STAGE"
mkdir -p "$STAGE" dist
cp -R build/SoundRouter.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read Me First.txt" <<TXT
SoundRouter $VERSION
Send each app's sound, or a single browser tab, to the speaker you choose.
Requires macOS 15 or later.

INSTALL
1. Drag SoundRouter into the Applications folder.
2. Open it. Because the app isn't notarized by Apple, macOS will say it
   "could not verify" SoundRouter. Click Done, then open
   System Settings > Privacy & Security, scroll down and click
   "Open Anyway" next to SoundRouter. You only need to do this once.
3. The first time you send an app to a speaker, allow SoundRouter to
   record system audio. It uses this to move app audio between speakers;
   it never records your microphone.

SoundRouter lives in the menu bar (the speaker icon).

ROUTING SINGLE BROWSER TABS (optional, Chrome / Brave / Edge)
1. Open chrome://extensions and turn on Developer mode.
2. Click "Load unpacked", press Command-Shift-G, paste
   ~/Library/Application Support/SoundRouter/BrowserExtension
   and choose that folder. (SoundRouter creates it when it first runs.)
3. In a tab, click the SoundRouter toolbar button and pick a speaker.

KEYBOARD SHORTCUTS (Control-Option-Command +)
  S       switch the Mac default speaker
  M       mute / unmute the app in front
  Up/Down louder / quieter: the app in front
  1-9     apply preset 1-9
  0       open the SoundRouter panel
TXT

DMG="dist/SoundRouter-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "SoundRouter $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "Created $DMG"
