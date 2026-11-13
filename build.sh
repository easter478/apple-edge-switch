#!/bin/zsh
# Builds "Edge Switch.app" into ./build and installs it to ~/Applications.
# Needs only the Xcode Command Line Tools (swiftc). No Xcode project.
#   ./build.sh            build + install + start
#   ./build.sh --no-run   build + install, do not start it
# NOTE: the app is signed ad hoc, so every rebuild is a new app to macOS and the
# Accessibility permission has to be switched on again (System Settings > Privacy & Security).
set -e
cd "${0:A:h}"
NAME="Edge Switch"
ID="local.easter.edgeswitch"
VERSION="1.2.0"
OUT="build"
APP="$OUT/$NAME.app"
DEST="$HOME/Applications/$NAME.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -swift-version 5 -O -target arm64-apple-macos14.0 Sources/*.swift -o "$APP/Contents/MacOS/EdgeSwitch"

# icon
ICONSET="$OUT/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
"$APP/Contents/MacOS/EdgeSwitch" --make-icon "$OUT/icon-1024.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$OUT/icon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$OUT/icon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleExecutable</key><string>EdgeSwitch</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force -s - --identifier "$ID" "$APP"

# install: close the running copy first, then replace it
osascript -e "tell application id \"$ID\" to quit" 2>/dev/null || true
pkill -x EdgeSwitch 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
# The rebuilt app is a new app to macOS. Clear its old Accessibility entry so macOS asks again
# instead of showing a switch that is on but no longer works.
tccutil reset Accessibility "$ID" >/dev/null 2>&1 || true
echo "Built $APP"
echo "Installed $DEST"
if [[ "$1" != "--no-run" ]]; then open "$DEST"; echo "Started"; fi
