#!/bin/zsh
# One-line installer for Edge Switch: downloads the latest release and puts it in Applications.
#   curl -fsSL https://raw.githubusercontent.com/easter478/apple-edge-switch/main/install.sh | zsh
set -e
REPO="easter478/apple-edge-switch"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "Finding the latest Edge Switch release..."
URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
  | grep -o '"browser_download_url": *"[^"]*\.zip"' | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')
[[ -n "$URL" ]] || { echo "No release found."; exit 1; }

echo "Downloading $URL"
curl -fsSL "$URL" -o "$TMP/EdgeSwitch.zip"
ditto -x -k "$TMP/EdgeSwitch.zip" "$TMP"

DEST="/Applications"
[[ -w "$DEST" ]] || DEST="$HOME/Applications"
mkdir -p "$DEST"
osascript -e 'tell application id "local.easter.edgeswitch" to quit' 2>/dev/null || true
rm -rf "$DEST/Edge Switch.app"
cp -R "$TMP/Edge Switch.app" "$DEST/"
# Downloaded by this script, not a browser, so macOS does not block the first start.
xattr -dr com.apple.quarantine "$DEST/Edge Switch.app" 2>/dev/null || true

echo "Installed to $DEST/Edge Switch.app"
open "$DEST/Edge Switch.app"
echo "Started. Switch on Edge Switch in System Settings > Privacy & Security > Accessibility when asked."
