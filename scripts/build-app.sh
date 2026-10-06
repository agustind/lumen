#!/usr/bin/env bash
# Builds build/Lumen.app from the Swift package.
#
#   scripts/build-app.sh                 # release build; uses libmpv/node from Stremio.app or Homebrew at runtime
#   scripts/build-app.sh --standalone    # also bundles libmpv + the streaming server (node, server.js, ffmpeg)
#   scripts/build-app.sh --debug         # debug configuration
#
# For --standalone, libmpv comes from an installed Stremio.app (preferred, it ships a
# self-contained libmpv) or from Homebrew (`brew install mpv dylibbundler`).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG=release
STANDALONE=0
for arg in "$@"; do
    case "$arg" in
        --standalone) STANDALONE=1 ;;
        --debug) CONFIG=debug ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

APP="$ROOT/build/Lumen.app"
CONTENTS="$APP/Contents"
VERSION="$(cat "$ROOT/VERSION" 2>/dev/null || echo 1.0.0)"
STREMIO_APP="/Applications/Stremio.app/Contents/MacOS"

echo "==> Building ($CONFIG)"
cd "$ROOT"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks"
cp "$BIN_DIR/Lumen" "$CONTENTS/MacOS/Lumen"
cp -R "$BIN_DIR/Lumen_Lumen.bundle" "$CONTENTS/Resources/"

if [[ ! -f "$ROOT/Resources/AppIcon.icns" ]]; then
    echo "==> Rendering icon"
    TMP="$(mktemp -d)"
    swift "$ROOT/scripts/make-icon.swift" "$TMP/icon_1024.png" >/dev/null
    ICONSET="$TMP/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z $size $size "$TMP/icon_1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        sips -z $((size * 2)) $((size * 2)) "$TMP/icon_1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"
    rm -rf "$TMP"
fi
cp "$ROOT/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"

sed -e "s/__VERSION__/$VERSION/g" "$ROOT/Resources/Info.plist" > "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"

if [[ "$STANDALONE" == 1 ]]; then
    if [[ -f "$STREMIO_APP/libmpv.2.dylib" ]]; then
        echo "==> Bundling libmpv from Stremio.app"
        # libmpv and its dependencies use @rpath; the app's rpath includes Contents/Frameworks.
        cp "$STREMIO_APP"/*.dylib "$CONTENTS/Frameworks/"
    elif [[ -f /opt/homebrew/lib/libmpv.2.dylib ]] && command -v dylibbundler >/dev/null; then
        echo "==> Bundling libmpv from Homebrew"
        cp /opt/homebrew/lib/libmpv.2.dylib "$CONTENTS/Frameworks/"
        chmod u+w "$CONTENTS/Frameworks/libmpv.2.dylib"
        install_name_tool -id @rpath/libmpv.2.dylib "$CONTENTS/Frameworks/libmpv.2.dylib"
        dylibbundler -of -b -x "$CONTENTS/Frameworks/libmpv.2.dylib" -d "$CONTENTS/Frameworks/" -p @rpath/ >/dev/null
    else
        echo "!! No bundleable libmpv found (install Stremio, or: brew install mpv dylibbundler)" >&2
    fi

    echo "==> Bundling streaming server"
    SERVER_DIR="$CONTENTS/Resources/server"
    mkdir -p "$SERVER_DIR"
    if [[ -f "$STREMIO_APP/server.js" ]]; then
        cp "$STREMIO_APP/server.js" "$STREMIO_APP/node" "$SERVER_DIR/"
        [[ -f "$STREMIO_APP/ffmpeg" ]] && cp "$STREMIO_APP/ffmpeg" "$STREMIO_APP/ffprobe" "$SERVER_DIR/"
    else
        curl -fL "$(cat "$ROOT/Resources/server-url.txt")" -o "$SERVER_DIR/server.js"
        NODE="$(command -v node || true)"
        if [[ -n "$NODE" ]]; then cp "$NODE" "$SERVER_DIR/node"; fi
    fi
fi

echo "==> Signing (ad-hoc)"
for dir in "$CONTENTS/Frameworks" "$CONTENTS/Resources/server"; do
    [[ -d "$dir" ]] || continue
    find "$dir" -type f \( -name "*.dylib" -o -perm -u+x \) -print0 \
        | while IFS= read -r -d '' file; do codesign --force --sign - "$file" >/dev/null 2>&1 || true; done
done
codesign --force --sign - --entitlements "$ROOT/Resources/Lumen.entitlements" "$APP"

echo "==> Done: $APP"
du -sh "$APP" | awk '{print "    size: " $1}'
