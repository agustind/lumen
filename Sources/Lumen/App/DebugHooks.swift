import AppKit

/// Development aid, active only when launched with `LUMEN_DEBUG=1`:
/// posting the distributed notification `dev.lumen.snapshot` with a file path as
/// the object writes a PNG of the main window there (apps may capture their own windows
/// without the Screen Recording permission). Used for automated UI checks.
enum DebugHooks {
    static func install() {
        guard ProcessInfo.processInfo.environment["LUMEN_DEBUG"] == "1" else { return }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("dev.lumen.snapshot"), object: nil, queue: .main
        ) { note in
            guard let path = note.object as? String else { return }
            MainActor.assumeIsolated { snapshot(to: path) }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("dev.lumen.state"), object: nil, queue: .main
        ) { note in
            guard let path = note.object as? String else { return }
            MainActor.assumeIsolated { dumpState(to: path) }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("dev.lumen.command"), object: nil, queue: .main
        ) { note in
            guard let command = note.object as? String else { return }
            MainActor.assumeIsolated { run(command) }
        }
        Log.info("Debug hooks installed")
    }

    static weak var app: AppState?
    @MainActor static var events: [String] = []

    /// `pause`, `play`, `seek:<seconds>`, `playmeta:<type>:<id>`, `close`, `url:<url>`, `section:<name>`, `search:<query>`.
    @MainActor
    private static func run(_ command: String) {
        guard let app else { return }
        let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "pause": app.player?.engine.setPaused(true)
        case "play": app.player?.engine.setPaused(false)
        case "seek": app.player?.seek(to: Double(argument) ?? 0)
        case "close": app.closePlayer()
        case "url": if let url = URL(string: argument) { app.handle(url: url) }
        case "section": if let section = SidebarSection(rawValue: argument) { app.section = section }
        case "search": app.search(argument)
        case "panel":
            NotificationCenter.default.post(name: .debugOpenPlayerPanel, object: argument)
        case "click":
            // click:<n> – opens the n-th item of the first Cinemeta movie catalog exactly like a poster click.
            Task {
                guard let addon = app.profile.activeAddons.first(where: { $0.manifest.id == "com.linvo.cinemeta" }),
                      let catalog = addon.manifest.catalogs.first(where: { $0.type == "movie" }),
                      let items = try? await AddonClient.shared.catalog(addon: addon, catalog: catalog),
                      let index = Int(argument), index < items.count else { return events.append("click failed") }
                events.append("click \(items[index].name)")
                app.openMeta(items[index])
            }
        case "playmeta":
            // playmeta:<type>:<id> – same path as picking the first stream on the detail page.
            let pieces = argument.split(separator: ":", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { return }
            Task {
                guard let meta = await app.fetchMeta(type: pieces[0], id: pieces[1]) else { return events.append("no meta") }
                let videoId = meta.behaviorHints.defaultVideoId ?? meta.id
                let addons = app.profile.addons(supporting: "stream", type: meta.type, id: videoId)
                events.append("meta \(meta.name); stream addons: \(addons.map(\.manifest.name))")
                for addon in addons {
                    if let stream = try? await AddonClient.shared.streams(addon: addon, type: meta.type, id: videoId).first(where: \.isPlayableInApp) {
                        events.append("playing \(stream.id) from \(addon.manifest.name)")
                        app.play(PlaybackRequest(stream: stream, meta: meta, videoId: videoId, addonTransportUrl: addon.transportUrl))
                        return
                    }
                }
            }
        default: Log.error("Unknown debug command \(command)")
        }
    }

    @MainActor
    private static func dumpState(to path: String) {
        var info: [String: Any] = ["section": app?.section.rawValue ?? "-", "server": "\(app?.server.status ?? .unknown)"]
        info["mpvLog"] = Array(MPVLibrary.log.suffix(15))
        info["events"] = events
        info["continueWatching"] = app?.library.continueWatching.map {
            "\($0.name) offset=\($0.state.timeOffset) duration=\($0.state.duration) watched=\($0.state.timeWatched) temp=\($0.temp) removed=\($0.removed)"
        } ?? []
        info["renderedFrames"] = MPVLayer.renderedFrames
        info["windowVisible"] = NSApp.windows.filter { $0.isVisible }.map { $0.occlusionState.contains(.visible) }
        info["appActive"] = NSApp.isActive
        info["centerPixel"] = MPVLayer.lastCenterPixel.map(Int.init)
        if let player = app?.player {
            let state = player.state
            info["player"] = [
                "engine": player.engine.name, "url": player.resolvedURL?.absoluteString ?? "", "error": (player.resolveError ?? state.error) ?? "",
                "loaded": state.isLoaded, "paused": state.isPaused, "buffering": state.isBuffering,
                "time": state.time, "duration": state.duration, "videoSize": state.videoSize.map { "\($0.width)x\($0.height)" } ?? "",
                "audioTracks": state.audioTracks.map(\.displayName), "subtitleTracks": state.subtitleTracks.map(\.displayName),
                "selectedSubtitle": state.selectedSubtitleId ?? "", "addonSubtitles": player.addonSubtitles.count,
                "peers": player.torrentStats?.peers ?? -1, "speed": player.torrentStats?.downloadSpeed ?? -1,
            ] as [String: Any]
        }
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    @MainActor
    private static func snapshot(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.level == .normal }) else { return }
        // View rendering first (reliable for SwiftUI content); a compositor capture is saved
        // alongside it because it also includes the video layer.
        if let image = windowImage(CGWindowID(window.windowNumber)) {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: path + ".window.png"))
        }
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            Log.error("Snapshot failed")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

/// `CGWindowListCreateImage` is hidden from the current SDK but still exported; capturing
/// our own window with it needs no Screen Recording permission.
private func windowImage(_ windowID: CGWindowID) -> CGImage? {
    typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
    let create = unsafeBitCast(symbol, to: CreateImage.self)
    // .optionIncludingWindow = 1 << 3; .boundsIgnoreFraming | .bestResolution = 1 | 8
    return create(.null, 1 << 3, windowID, 1 | 8)?.takeRetainedValue()
}

extension Notification.Name {
    static let debugOpenPlayerPanel = Notification.Name("dev.lumen.debug.panel")
}
