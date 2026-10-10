import AppKit
import Observation
import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case board, discover, library, search, addons, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .board: return "Board"
        case .discover: return "Discover"
        case .library: return "Library"
        case .search: return "Search"
        case .addons: return "Addons"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .board: return "house"
        case .discover: return "safari"
        case .library: return "books.vertical"
        case .search: return "magnifyingglass"
        case .addons: return "puzzlepiece.extension"
        case .settings: return "gearshape"
        }
    }
}

enum Route: Hashable {
    case meta(type: String, id: String, preview: MetaItem?)
    case catalog(addonTransportUrl: String, type: String, catalogId: String, genre: String?)
}

/// A request to open Discover at a particular catalog (from deep links or "See all").
struct DiscoverSelection: Hashable {
    var addonTransportUrl: String
    var type: String
    var catalogId: String
    var genre: String?
}

@MainActor
@Observable
final class AppState {
    let profile: ProfileStore
    let library: LibraryStore
    let server: StreamingServer

    var section: SidebarSection = .board
    var paths: [SidebarSection: [Route]] = [:]
    var player: PlayerSession?
    var searchQuery = ""
    var submittedSearch = ""
    /// Bumped to move keyboard focus to the toolbar search field (⌘F).
    var searchFocusRequest = 0
    var discoverSelection: DiscoverSelection?
    var pendingAddonInstall: AddonDescriptor?
    var alert: AlertMessage?
    var showLogin = false

    struct AlertMessage: Identifiable {
        let id = UUID()
        var title: String
        var message: String
    }

    init() {
        let profile = ProfileStore()
        self.profile = profile
        library = LibraryStore(profile: profile)
        server = StreamingServer(baseURL: profile.settings.streamingServerURL)
    }

    func bootstrap() async {
        async let serverStart: Void = server.start(autoLaunch: profile.settings.startStreamingServer)
        if profile.isLoggedIn {
            await profile.pullAddons()
            await library.sync()
        } else {
            await profile.refreshManifests()
        }
        await serverStart
    }

    // MARK: Navigation

    func path(for section: SidebarSection) -> Binding<[Route]> {
        Binding(
            get: { self.paths[section] ?? [] },
            set: { self.paths[section] = $0 }
        )
    }

    func push(_ route: Route) {
        paths[section, default: []].append(route)
    }

    func openMeta(_ meta: MetaItem) {
        push(.meta(type: meta.type, id: meta.id, preview: meta))
    }

    func openMeta(type: String, id: String) {
        push(.meta(type: type, id: id, preview: nil))
    }

    func search(_ query: String) {
        searchQuery = query
        submittedSearch = query
        section = .search
        paths[.search] = []
    }

    // MARK: Playback

    func play(_ request: PlaybackRequest) {
        guard request.stream.isPlayableInApp else {
            if case .external(let url) = request.stream.source { NSWorkspace.shared.open(url) }
            else if case .playerFrame(let url) = request.stream.source { NSWorkspace.shared.open(url) }
            else { alert = AlertMessage(title: "Can't play stream", message: "This stream type isn't supported.") }
            return
        }
        player?.close()
        player = PlayerSession(request: request, profile: profile, library: library, server: server)
    }

    /// Leaves the player and lands on the title's detail page (description, cast, resume).
    func closePlayer() {
        let meta = player?.request.meta
        player?.close()
        player = nil
        if let meta {
            if case .meta(_, let id, _)? = paths[section]?.last, id == meta.id {
                // Already underneath the player.
            } else {
                push(.meta(type: meta.type, id: meta.id, preview: meta))
            }
        }
        if let window = NSApp.keyWindow, window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
    }

    /// Resumes a "Continue watching" item with the last-used stream when known.
    func resume(_ item: LibraryItem) {
        if let last = library.lastStreams[item.id] {
            Task {
                let meta = await fetchMeta(type: item.type, id: item.id) ?? item.preview
                play(PlaybackRequest(stream: last.stream, meta: meta, videoId: item.state.videoId ?? last.videoId,
                                     addonTransportUrl: last.addonTransportUrl))
            }
        } else {
            openMeta(type: item.type, id: item.id)
        }
    }

    func fetchMeta(type: String, id: String) async -> MetaItem? {
        for addon in profile.addons(supporting: "meta", type: type, id: id) {
            if let meta = try? await AddonClient.shared.meta(addon: addon, type: type, id: id) { return meta }
        }
        return nil
    }

    // MARK: Addons

    func requestInstall(transportUrl: String) {
        Task {
            do {
                pendingAddonInstall = try await AddonClient.shared.fetchManifest(transportUrl: transportUrl)
            } catch {
                alert = AlertMessage(title: "Couldn't load addon", message: error.localizedDescription)
            }
        }
    }

    // MARK: Deep links

    /// Handles `lumen://` and `stremio://` links, `magnet:` links and addon manifest URLs.
    func handle(url: URL) {
        Log.info("Open URL: \(url)")
        // `lumen://` is an alias of `stremio://`, so every Stremio link works with either scheme.
        if url.scheme == "lumen", var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.scheme = "stremio"
            if let stremioURL = components.url { return handle(url: stremioURL) }
        }
        if url.scheme == "magnet" {
            guard let stream = Stream.fromMagnet(url) else { return }
            play(PlaybackRequest(stream: stream))
            return
        }
        if url.isFileURL, url.pathExtension.lowercased() == "torrent" {
            alert = AlertMessage(title: "Torrent files", message: "Opening .torrent files isn't supported yet. Use a magnet link instead.")
            return
        }
        guard url.scheme == "stremio" else {
            if url.absoluteString.hasSuffix("manifest.json") {
                requestInstall(transportUrl: url.absoluteString)
            } else if url.scheme == "http" || url.scheme == "https" || url.isFileURL {
                // A direct video link or local file.
                var stream = Stream(source: .url(url))
                stream.name = url.lastPathComponent
                play(PlaybackRequest(stream: stream))
            }
            return
        }
        // stremio://host/path/manifest.json → addon install
        if let host = url.host, !host.isEmpty {
            requestInstall(transportUrl: url.absoluteString)
            return
        }
        // stremio:///detail/{type}/{id}[/{videoId}], /search?search=, /discover/{addon}/{type}/{catalog}?genre=
        let components = url.path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        guard let route = components.first else { return }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch route {
        case "detail" where components.count >= 3:
            section = .board
            paths[.board] = [.meta(type: components[1], id: components[2], preview: nil)]
        case "search":
            if let q = query.first(where: { $0.name == "search" })?.value { search(q) }
        case "discover" where components.count >= 4:
            section = .discover
            paths[.discover] = []
            discoverSelection = DiscoverSelection(addonTransportUrl: components[1], type: components[2],
                                                  catalogId: components[3], genre: query.first(where: { $0.name == "genre" })?.value)
        case "library":
            section = .library
        case "addons":
            section = .addons
        case "settings":
            section = .settings
        default:
            break
        }
    }

    func handleLinkFromMeta(_ link: MetaLink) {
        guard let url = link.url else { return }
        if url.scheme == "stremio" || url.scheme == "lumen" {
            handle(url: url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Account

    func login(email: String, password: String) async throws {
        try await profile.login(email: email, password: password)
        library.resetForAccount(profile.auth?.user.id)
        await library.sync()
    }

    func register(email: String, password: String, marketing: Bool) async throws {
        try await profile.register(email: email, password: password, marketing: marketing)
        library.resetForAccount(profile.auth?.user.id)
        await library.sync()
    }

    func logout() async {
        await profile.logout()
        library.resetForAccount(nil)
    }

    func shutdown() {
        player?.close()
        library.saveNow()
        server.shutdown()
    }
}
