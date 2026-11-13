#!/bin/zsh
# Packages Edge Switch for a GitHub release.
#   ./release.sh             build, then make dist/Edge-Switch-<version>.dmg and .zip
#   ./release.sh --publish   same, then tag v<version> and create the GitHub release with both files
# The version comes from VERSION in build.sh. Release notes come from that version's
# section in CHANGELOG.md. Needs the GitHub CLI (gh) signed in for --publish.
set -e
cd "${0:A:h}"
VERSION=$(sed -n 's/^VERSION="\(.*\)"/\1/p' build.sh)
NAME="Edge Switch"
APP="build/$NAME.app"
DIST="dist"
BASE="Edge-Switch-$VERSION"

./build.sh --no-install

rm -rf "$DIST"; mkdir -p "$DIST"

# zip (keeps the app's signature and attributes)
ditto -c -k --keepParent "$APP" "$DIST/$BASE.zip"

# dmg: the app plus a shortcut to Applications, to drag onto
STAGE="$DIST/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$NAME $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DIST/$BASE.dmg" >/dev/null
rm -rf "${STAGE:?}"

(cd "$DIST" && shasum -a 256 "$BASE.dmg" "$BASE.zip" > "$BASE.sha256")

# release notes: the "## <version>" section of CHANGELOG.md
awk -v v="## $VERSION" '$0 ~ "^## " { p = (index($0, v) == 1) ; if (p) next } p' CHANGELOG.md > "$DIST/notes.md"
cat >> "$DIST/notes.md" <<'NOTES'

### Install
Download **Edge-Switch-VERSION.dmg**, open it and drag Edge Switch onto Applications. The first time, macOS may say it cannot check the app: open System Settings > Privacy & Security and click **Open Anyway**. Full steps are in the README.
NOTES
sed -i '' "s/VERSION/$VERSION/" "$DIST/notes.md"

echo "Made $DIST/$BASE.dmg"
echo "Made $DIST/$BASE.zip"

if [[ "$1" == "--publish" ]]; then
  GH="${GH:-$(command -v gh || echo "$HOME/.local/bin/gh")}"
  "$GH" release create "v$VERSION" "$DIST/$BASE.dmg" "$DIST/$BASE.zip" "$DIST/$BASE.sha256" \
    --title "$NAME $VERSION" --notes-file "$DIST/notes.md" --target main
  echo "Published v$VERSION"
fi
