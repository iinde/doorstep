#!/bin/bash
# Build Doorstep (Debug), then re-sign it with a stable Apple Development certificate so
# macOS Keychain "Always Allow" survives rebuilds (ad-hoc builds re-prompt every time).
# No entitlements: matches how the app has run so far (not sandboxed).
set -euo pipefail
cd "$(dirname "$0")/../app"
# Signing identity: $DOORSTEP_SIGN_CERT, else your first "Apple Development" certificate,
# else ad-hoc ("-", works locally but macOS asks for Keychain access after each rebuild).
CERT="${DOORSTEP_SIGN_CERT:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/{print $2; exit}')}"
CERT="${CERT:--}"
xcodebuild -project OpenRing.xcodeproj -scheme OpenRing -configuration Debug \
  -derivedDataPath build CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
  build 2>&1 | grep -E ' error:|BUILD (SUCCEEDED|FAILED)' | sort -u
APP=build/Build/Products/Debug/OpenRing.app
codesign --force --deep --timestamp=none --sign "$CERT" "$APP"
codesign --verify --deep "$APP" && echo "Signed: $(codesign -dv "$APP" 2>&1 | grep -m1 '^TeamIdentifier=')"
