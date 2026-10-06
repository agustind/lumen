# Lumen

A native macOS client for [Stremio](https://github.com/Stremio) addons, written in Swift/SwiftUI.
Lumen works with your Stremio account, addons and library, but it's an independent project, not an
official Stremio app.

The official desktop apps ([stremio-shell](https://github.com/Stremio/stremio-shell) and the Stremio 5
Mac app) wrap the [stremio-web](https://github.com/Stremio/stremio-web) UI in a web view. This
project replaces the web UI with real AppKit/SwiftUI screens. It keeps the parts that already work
well natively: **libmpv** for playback and Stremio's **streaming server** (`server.js`) for torrents.

## Features

- **Board**: hero banner, Continue Watching, and every catalog from your installed addons
- **Discover**: browse any catalog by type, catalog and genre, with infinite scroll
- **Library**: filter by type, sort, and filter by text; synced with your Stremio account
- **Search**: searches every addon catalog that supports it
- **Detail pages**: logo, rating, genres, cast; seasons and episodes with watched marks; streams grouped by addon
- **Player**: mpv rendered via the OpenGL render API (hardware decoding, every container and codec)
  - Embedded and addon subtitles (OpenSubtitles), with auto-selection by language and delay adjustment
  - Audio tracks, playback speed, switching streams without leaving the player
  - Next-episode card, plus binge-watching via the stream's `bingeGroup`
  - Torrent stats (peers, speed) while buffering
  - Now Playing / media keys, sleep prevention, immersive full-screen window chrome
- **Addons**: installed, Official and Community lists, install by URL or `stremio://`/`lumen://` link, configure, uninstall
- **Account**: log in or sign up; addon collection and library sync through `api.strem.io`
  (same datastore as the official apps, including the watched-episodes bitfield)
- **Deep links**: `stremio:///detail/…`, `stremio:///search?search=…`, `stremio://…/manifest.json`, `magnet:`.
  Every `stremio://` link also works as `lumen://`, which is handy when the official app is installed and
  claims `stremio://`.

AVFoundation is used as a fallback when libmpv isn't available. It plays MP4/HLS but not MKV.

## Install

Download `Lumen-<version>.dmg` from [Releases](https://github.com/agustind/lumen/releases), open it and drag
Lumen to Applications. The release build bundles libmpv and the streaming server, so nothing else is needed.
It runs on Apple Silicon Macs with macOS 15 or later. The app is signed and notarized by Apple.

## Building from source

- macOS 15+, Xcode 16+ (Swift 6 toolchain)
- **libmpv**, from either source:
  - an installed **Stremio.app** (its bundled libmpv is used automatically), or
  - Homebrew: `brew install mpv`
- **Streaming server** (for torrents and YouTube):
  - If something already listens on `127.0.0.1:11470` (e.g. Stremio or stremio-service), it's used as-is.
  - Otherwise the app launches `server.js` with Node: the copies inside Stremio.app, or Homebrew/nvm
    `node` plus a downloaded `server.js`.

## Build & run

```sh
scripts/build-app.sh               # → build/Lumen.app (relies on Stremio.app/Homebrew at runtime)
scripts/build-app.sh --standalone  # also bundles libmpv, node, server.js and ffmpeg into the app
open build/Lumen.app

scripts/make-dmg.sh                # → build/Lumen-<version>.dmg from build/Lumen.app

# Signed + notarized release (Developer ID and a `notarytool store-credentials` profile)
export SIGN_IDENTITY="Developer ID Application: …"
scripts/build-app.sh --standalone && NOTARY_PROFILE=<profile> scripts/make-dmg.sh

swift test                         # unit tests (addon protocol, library format, watched bitfield)
```

You can also open `Package.swift` in Xcode and run the `Lumen` scheme. Some features need a real
`.app` bundle: URL schemes, and the ATS exceptions for plain-HTTP addons.

## Keyboard shortcuts (player)

| Key | Action |
| --- | --- |
| Space | Play / pause |
| ← / → (⇧ for 3×) | Seek by the configured step |
| ↑ / ↓ | Volume |
| F | Full screen |
| M | Mute |
| N | Next episode |
| [ / ] | Speed − / + |
| G / H | Subtitle delay − / + |
| Esc | Exit full screen / close player |

App-wide: ⌘1–⌘6 switch sections, ⌘[ goes back, ⌘F searches, ⇧⌘O opens a magnet or video link from the clipboard.

## Layout

```
Sources/CMpv/                 libmpv headers (ISC) + a dlopen-based loader
Sources/Lumen/
  App/                        app entry, AppState (navigation, deep links), debug hooks
  Core/Models/                addon protocol, meta/stream/library types, watched bitfield
  Core/API/                   api.strem.io client (auth, addon collection, datastore)
  Core/Addons/                addon transport (resource URLs, caching)
  Core/Stores/                profile/settings and library stores (persistence + sync)
  Core/Server/                streaming server lifecycle and API (torrents, proxy, opensubHash)
  Player/                     PlayerSession, engines (mpv, AVFoundation), player UI, Now Playing
  UI/                         Board, Discover, Library, Search, Detail, Addons, Settings
Tests/LumenTests/             model and protocol tests
scripts/build-app.sh          bundles build/Lumen.app; make-icon.swift renders the icon
scripts/make-dmg.sh           packages the app into a DMG
```

Data lives in `~/Library/Application Support/Lumen/` (moved automatically from `Stremio Native/`, the pre-rename location).

## Development notes

Launch with `LUMEN_DEBUG=1` (`open --env LUMEN_DEBUG=1 build/Lumen.app`) to enable debug hooks.
These are distributed notifications for window snapshots, a state dump and simple commands, used for
automated UI checks. See `Sources/Lumen/App/DebugHooks.swift`.

## Not implemented yet

Calendar and notifications, Trakt, Chromecast, `.torrent` files, archive streams (rar/zip),
casting, and the intro/outro skip API.

## Licensing

Lumen's own code is released under the [MIT License](LICENSE). The libmpv headers in `Sources/CMpv/include`
are ISC-licensed by the mpv developers. Release builds bundle third-party binaries (libmpv, FFmpeg and
their dependencies, Node.js and Stremio's streaming server), which keep their own licenses.

Stremio's code is GPL-licensed and its name and logo are trademarks of Smart Code Ltd. Lumen is not
affiliated with or endorsed by Smart Code Ltd. This project
reuses Stremio's protocols, its public API and (at runtime) its streaming server. Check those terms
before redistributing builds, especially `--standalone` builds, which bundle Stremio's binaries.
