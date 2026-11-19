#!/bin/bash
# Build, sign and package a Doorstep release, and (with --publish) put it on GitHub.
#
#   scripts/release.sh 0.2.0            # build dist/Doorstep-0.2.0.dmg + dist/appcast.xml, nothing uploaded
#   scripts/release.sh 0.2.0 --publish  # same, then create the GitHub release the app updates from
#
# Needs: release notes in docs/releases/<version>.md (written by a person, grouped, benefit first).
# Signing: the Apple Development cert (code) and the Sparkle EdDSA key "doorstep" in the login
# Keychain (updates). Backup of the EdDSA key: ~/doorstep_private_keys (never in git).
# No server: the app reads appcast.xml from the newest release of $REPO.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD

VERSION="${1:?usage: scripts/release.sh <version> [--publish]}"
PUBLISH="${2:-}"
REPO=$(grep -E '^DOORSTEP_RELEASES_REPO' app/Config/Shared.xcconfig | sed 's/.*= *//')
# Signing identity: $DOORSTEP_SIGN_CERT, else your first "Apple Development" certificate,
# else ad-hoc ("-", works locally but macOS asks for Keychain access after each rebuild).
CERT="${DOORSTEP_SIGN_CERT:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/{print $2; exit}')}"
CERT="${CERT:--}"
NOTES_MD="docs/releases/$VERSION.md"
SPARKLE_BIN=app/OpenRingPackage/.build/artifacts/sparkle/Sparkle/bin
[ -f "$NOTES_MD" ] || { echo "Write $NOTES_MD first."; exit 1; }
[ -x "$SPARKLE_BIN/sign_update" ] || (cd app/OpenRingPackage && swift package resolve >/dev/null)

# Version: marketing = what people see; build = what Sparkle compares. Build always goes up.
BUILD=$(( $(grep -E '^CURRENT_PROJECT_VERSION' app/Config/Shared.xcconfig | sed 's/.*= *//') + 1 ))
sed -i '' -E "s/^MARKETING_VERSION = .*/MARKETING_VERSION = $VERSION/; s/^CURRENT_PROJECT_VERSION = .*/CURRENT_PROJECT_VERSION = $BUILD/" app/Config/Shared.xcconfig
echo "▸ Doorstep $VERSION (build $BUILD)"

# 1. Universal Release build (from clean: a previous app left in place can't be overwritten).
BUILT=app/build-release/Build/Products/Release/OpenRing.app
[ -d "$BUILT" ] && { chmod -R u+w "$BUILT"; rm -rf "$BUILT"; }
(cd app && xcodebuild -project OpenRing.xcodeproj -scheme OpenRing -configuration Release \
  -derivedDataPath build-release ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO build 2>&1 | grep -E ' error:|BUILD (SUCCEEDED|FAILED)' | sort -u)
BUILT=app/build-release/Build/Products/Release/OpenRing.app
[ -d "$BUILT" ] || { echo "Build failed."; exit 1; }

# 2. Stage as Doorstep.app and sign, inside out (Sparkle's helpers keep their entitlements).
STAGE=$(mktemp -d)
cp -R "$BUILT" "$STAGE/Doorstep.app"
APP="$STAGE/Doorstep.app"
SP="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for item in "$SP/XPCServices/Installer.xpc" "$SP/XPCServices/Downloader.xpc" "$SP/Autoupdate" "$SP/Updater.app"; do
  [ -e "$item" ] && codesign --force --timestamp=none --options runtime --preserve-metadata=entitlements --sign "$CERT" "$item"
done
for fw in "$APP"/Contents/Frameworks/*.framework; do codesign --force --timestamp=none --options runtime --sign "$CERT" "$fw"; done
codesign --force --timestamp=none --options runtime --entitlements "$(dirname "$0")/release.entitlements" --sign "$CERT" "$APP"
codesign --verify --deep --strict "$APP"
echo "▸ Signed ($(codesign -dv "$APP" 2>&1 | grep -m1 TeamIdentifier))"
# The thing the colleague crash taught us: never ship the SwiftUI VideoPlayer wrapper.
if nm -u "$APP/Contents/MacOS/OpenRing" 2>/dev/null | grep -q _AVKit_SwiftUI; then
  echo "✗ Binary references SwiftUI VideoPlayer (crashes Release builds). Use ClipPlayerView."; exit 1
fi

# 3. Styled installer DMG: background, icon positions, Applications shortcut.
mkdir -p dist/releases
rm -f dist/releases/*
DMG="dist/releases/Doorstep-$VERSION.dmg"
RW="$STAGE/rw.dmg"
swift scripts/dmg-background.swift "$STAGE/background.png" >/dev/null
hdiutil create -quiet -size 160m -fs HFS+ -volname "Doorstep" -ov "$RW"
MNT=$(hdiutil attach -nobrowse -noautoopen "$RW" | awk -F'\t' '/\/Volumes\//{print $NF}')
cp -R "$APP" "$MNT/"
ln -s /Applications "$MNT/Applications"
mkdir "$MNT/.background" && cp "$STAGE/background.png" "$MNT/.background/background.png"
osascript <<APPLESCRIPT || echo "  (Finder layout skipped: allow Terminal to control Finder for the styled window)"
tell application "Finder"
  tell disk "Doorstep"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 568}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:background.png"
    set position of item "Doorstep.app" of container window to {180, 210}
    set position of item "Applications" of container window to {480, 210}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
SetFile -a V "$MNT/.background" 2>/dev/null || true
sync
hdiutil detach -quiet "$MNT"
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"
hdiutil verify -quiet "$DMG" && echo "▸ $DMG ($(du -h "$DMG" | cut -f1))"

# 4. Release notes as HTML (shown in the update window), then the signed appcast.
python3 - "$NOTES_MD" "dist/releases/Doorstep-$VERSION.html" <<'PY'
import sys, html, re
md = open(sys.argv[1]).read().splitlines()
out, in_list = [], False
for line in md:
    t = line.strip()
    if t.startswith("- "):
        if not in_list: out.append("<ul>"); in_list = True
        item = html.escape(t[2:])
        out.append("<li>" + re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", item) + "</li>"); continue
    if in_list: out.append("</ul>"); in_list = False
    if t.startswith("## "): out.append("<h3>" + html.escape(t[3:]) + "</h3>")
    elif t.startswith("# "): continue
    elif t: out.append("<p>" + re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", html.escape(t)) + "</p>")
if in_list: out.append("</ul>")
style = "<style>body{font:13px -apple-system;margin:12px}h3{font-size:13px;margin:14px 0 4px}ul{padding-left:18px;margin:0}li{margin:3px 0}</style>"
open(sys.argv[2], "w").write("<html><head><meta charset='utf-8'>" + style + "</head><body>" + "\n".join(out) + "</body></html>")
PY
# Fresh every time: generate_appcast merges into an existing file, which kept stale test items.
rm -f dist/appcast.xml
"$SPARKLE_BIN/generate_appcast" --account doorstep --maximum-deltas 0 --embed-release-notes \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
  -o dist/appcast.xml dist/releases 2>&1 | grep -v deprecated
grep -q "sparkle:edSignature" dist/appcast.xml && echo "▸ dist/appcast.xml signed for $VERSION"
cp "$DMG" dist/
rm -rf "$STAGE"

if [ "$PUBLISH" != "--publish" ]; then
  echo "Built, not published. Run again with --publish to release to github.com/$REPO."
  exit 0
fi

# 5. Publish: the release holds the DMG (download) and appcast.xml (what the app checks).
gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1 && { echo "v$VERSION already exists on $REPO."; exit 1; }
gh release create "v$VERSION" "$DMG" dist/appcast.xml --repo "$REPO" \
  --title "Doorstep $VERSION" --notes-file "$NOTES_MD" --latest
echo "▸ Published https://github.com/$REPO/releases/tag/v$VERSION"
# Also on the source repo, so its Releases sidebar offers the download (no feed there).
SOURCE_REPO="${DOORSTEP_SOURCE_REPO:-iinde/doorstep}"
gh release create "v$VERSION" "$DMG" --repo "$SOURCE_REPO" --title "Doorstep $VERSION" --notes-file "$NOTES_MD" --latest \
  && echo "▸ Also on https://github.com/$SOURCE_REPO/releases/tag/v$VERSION"
