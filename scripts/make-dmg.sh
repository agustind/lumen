#!/usr/bin/env bash
# Packages build/Lumen.app into build/Lumen-<version>.dmg with an Applications shortcut.
#   scripts/make-dmg.sh                # packages whatever build/Lumen.app currently is
#   scripts/build-app.sh --standalone && scripts/make-dmg.sh   # release build
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Lumen.app"
VERSION="$(cat "$ROOT/VERSION" 2>/dev/null || echo 1.0.0)"
DMG="$ROOT/build/Lumen-$VERSION.dmg"

[[ -d "$APP" ]] || { echo "!! $APP not found, run scripts/build-app.sh first" >&2; exit 1; }

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "==> Creating $DMG"
rm -f "$DMG"
hdiutil create -volname "Lumen" -srcfolder "$STAGING" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
du -sh "$DMG" | awk '{print "    size: " $1}'
