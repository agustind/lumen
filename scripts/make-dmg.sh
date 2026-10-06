#!/usr/bin/env bash
# Packages build/Lumen.app into build/Lumen-<version>.dmg with an Applications shortcut.
#   scripts/make-dmg.sh                # packages whatever build/Lumen.app currently is
#   scripts/build-app.sh --standalone && scripts/make-dmg.sh   # release build
#
# For a notarized release, sign the app with a Developer ID and pass a notarytool keychain profile
# (created once with `xcrun notarytool store-credentials <profile>`):
#   export SIGN_IDENTITY="Developer ID Application: …"
#   scripts/build-app.sh --standalone && NOTARY_PROFILE=<profile> scripts/make-dmg.sh
# The app is notarized and stapled first, then the DMG is signed, notarized and stapled.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Lumen.app"
VERSION="$(cat "$ROOT/VERSION" 2>/dev/null || echo 1.0.0)"
DMG="$ROOT/build/Lumen-$VERSION.dmg"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"

[[ -d "$APP" ]] || { echo "!! $APP not found, run scripts/build-app.sh first" >&2; exit 1; }
if [[ -n "$NOTARY_PROFILE" && -z "$SIGN_IDENTITY" ]]; then
    echo "!! NOTARY_PROFILE needs SIGN_IDENTITY (the Developer ID the app was signed with)" >&2
    exit 1
fi

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

# Submits a file to Apple's notary service and waits; prints the log and fails if it's rejected.
notarize() {
    local file="$1" result id status
    echo "==> Notarizing $(basename "$file") (this usually takes a few minutes)"
    result="$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)"
    id="$(plutil -extract id raw - <<<"$result")"
    status="$(plutil -extract status raw - <<<"$result")"
    echo "    $status ($id)"
    if [[ "$status" != "Accepted" ]]; then
        xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2
        exit 1
    fi
}

if [[ -n "$NOTARY_PROFILE" ]]; then
    ditto -c -k --keepParent "$APP" "$STAGING/Lumen.zip"
    notarize "$STAGING/Lumen.zip"
    rm "$STAGING/Lumen.zip"
    xcrun stapler staple -q "$APP"
fi

mkdir "$STAGING/dmg"
cp -R "$APP" "$STAGING/dmg/"
ln -s /Applications "$STAGING/dmg/Applications"

echo "==> Creating $DMG"
rm -f "$DMG"
hdiutil create -volname "Lumen" -srcfolder "$STAGING/dmg" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null 2>&1

if [[ -n "$SIGN_IDENTITY" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
fi
if [[ -n "$NOTARY_PROFILE" ]]; then
    notarize "$DMG"
    xcrun stapler staple -q "$DMG"
fi
du -sh "$DMG" | awk '{print "    size: " $1}'
