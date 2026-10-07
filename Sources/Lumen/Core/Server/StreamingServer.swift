import Foundation
import Observation

/// Manages Stremio's streaming server (`server.js`, the torrent/HLS engine used by every
/// Stremio desktop app). Uses an already-running server when present, otherwise launches one.
@MainActor
@Observable
final class StreamingServer {
    enum Status: Equatable {
        case unknown
        case starting
        case running(version: String?, external: Bool)
        case stopped
        case failed(String)

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    struct TorrentStats: Decodable, Sendable {
        var peers: Int?
        var unchoked: Int?
        var downloadSpeed: Double?
        var uploadSpeed: Double?
        var downloaded: Double?
        var streamProgress: Double?
        var streamName: String?
    }

    private(set) var status: Status = .unknown
    private(set) var log: [String] = []
    var baseURL: URL

    private var process: Process?
    private var restartAttempts = 0
    private var stoppingDeliberately = false

    static let serverJSDownload = URL(string: "https://dl.strem.io/server/v4.20.16/desktop/server.js")!

    init(baseURL: String) {
        self.baseURL = URL(string: baseURL) ?? URL(string: "http://127.0.0.1:11470")!
    }

    // MARK: Lifecycle

    func start(autoLaunch: Bool) async {
        if await probe() { return }
        guard autoLaunch else {
            status = .stopped
            return
        }
        await launch()
    }

    /// Checks whether a server responds at `baseURL`, updating `status`.
    @discardableResult
    func probe() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("settings"))
        request.timeoutInterval = 2
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        let version = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            .flatMap { ($0["values"] as? [String: Any])?["serverVersion"] as? String }
        status = .running(version: version, external: process == nil)
        return true
    }

    func restart() async {
        stop()
        try? await Task.sleep(for: .milliseconds(500))
        restartAttempts = 0
        await launch()
    }

    func stop() {
        stoppingDeliberately = true
        process?.terminate()
        process = nil
        status = .stopped
    }

    private func launch() async {
        status = .starting
        guard let node = Self.findNode() else {
            status = .failed("Node.js was not found. Install Stremio or Node.js to enable torrent streaming.")
            return
        }
        let serverJS: URL
        do {
            serverJS = Self.patchedForCasting(try await Self.findOrDownloadServerJS())
        } catch {
            status = .failed("Could not download server.js: \(error.localizedDescription)")
            return
        }

        let process = Process()
        process.executableURL = node
        process.arguments = [serverJS.path]
        var env = ProcessInfo.processInfo.environment
        env["NO_CORS"] = "1"
        if let ffmpeg = Self.findBinary("ffmpeg", near: node) { env["FFMPEG_BIN"] = ffmpeg.path }
        if let ffprobe = Self.findBinary("ffprobe", near: node) { env["FFPROBE_BIN"] = ffprobe.path }
        process.environment = env
        process.currentDirectoryURL = Storage.directory

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.appendLog(text) }
        }
        process.terminationHandler = { [weak self] proc in
            Task { @MainActor in self?.handleTermination(code: proc.terminationStatus) }
        }

        do {
            stoppingDeliberately = false
            try process.run()
            self.process = process
            Log.info("Streaming server launched: \(node.path) \(serverJS.path)")
        } catch {
            status = .failed("Failed to launch streaming server: \(error.localizedDescription)")
            return
        }

        // Wait for the HTTP endpoint to come up.
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(250))
            if await probe() {
                restartAttempts = 0
                return
            }
            if self.process == nil { return }
        }
        status = .failed("Streaming server did not respond.")
    }

    private func appendLog(_ text: String) {
        log.append(contentsOf: text.split(separator: "\n").map(String.init))
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    private func handleTermination(code: Int32) {
        process = nil
        guard !stoppingDeliberately else { return }
        Log.error("Streaming server exited with code \(code)")
        if restartAttempts < 3 {
            restartAttempts += 1
            Task { await launch() }
        } else {
            status = .failed("Streaming server crashed (exit code \(code)).")
        }
    }

    /// Terminates a server we launched. Called on app quit.
    func shutdown() {
        stoppingDeliberately = true
        process?.terminate()
        process = nil
    }

    // MARK: Locating node / server.js

    private static let stremioAppDirs = [
        "/Applications/Stremio.app/Contents/MacOS",
        NSHomeDirectory() + "/Applications/Stremio.app/Contents/MacOS",
    ]

    private static var bundledDir: URL? { Bundle.main.resourceURL?.appendingPathComponent("server") }

    static func findNode() -> URL? {
        var candidates: [String] = []
        if let bundled = bundledDir { candidates.append(bundled.appendingPathComponent("node").path) }
        candidates += stremioAppDirs.map { $0 + "/node" }
        candidates += ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
        // nvm installs: pick the newest version.
        let nvm = NSHomeDirectory() + "/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            candidates += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { "\(nvm)/\($0)/bin/node" }
        }
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }
        return shellWhich("node")
    }

    static func findBinary(_ name: String, near node: URL) -> URL? {
        let candidates = [
            node.deletingLastPathComponent().appendingPathComponent(name).path,
        ] + stremioAppDirs.map { "\($0)/\(name)" } + ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    private static func shellWhich(_ command: String) -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(command)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return output.isEmpty ? nil : URL(fileURLWithPath: output)
    }

    static func findOrDownloadServerJS() async throws -> URL {
        var candidates: [String] = []
        if let bundled = bundledDir { candidates.append(bundled.appendingPathComponent("server.js").path) }
        candidates += stremioAppDirs.map { $0 + "/server.js" }
        let downloaded = Storage.url("server.js")
        candidates.append(downloaded.path)
        if let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }
        let (temp, response) = try await URLSession.shared.download(from: serverJSDownload)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        try? FileManager.default.removeItem(at: downloaded)
        try FileManager.default.moveItem(at: temp, to: downloaded)
        return downloaded
    }

    /// Fixes to server.js's casting, applied to a copy that's launched instead of the original.
    /// Each patch is skipped if its code isn't found (a different server version).
    private static let castingPatches: [(original: String, patched: String)] = [
        // The Chromecast client gives up on any message after 5s, which TVs on a slow or
        // power-saving Wi-Fi link regularly exceed (connecting and launching the receiver take
        // several round trips).
        ("ChromecastClient.MESSAGE_TIMEOUT = 5e3", "ChromecastClient.MESSAGE_TIMEOUT = 3e4"),
        // Cap cast video at 1080p: HD Chromecasts drop 4K streams, and smaller video transcodes
        // faster and survives weak Wi-Fi. H.264 above 1080p is re-encoded instead of copied...
        (#""Video" == stream.type && "h264" == stream.codec;"#,
         #""Video" == stream.type && "h264" == stream.codec && !(+(/\d+x(\d+)/.exec(stream.vidfmt || "") || [])[1] > 1080);"#),
        // ...and every re-encode is scaled down (keeping burned-in subtitles for DLNA).
        (#"subtitles && args.push("-vf", "subtitles=" + subtitles)"#,
         #"args.push("-vf", "scale=-2:'min(1080,ih)'" + (subtitles ? ",subtitles=" + subtitles : ""))"#),
    ]

    private static func patchedForCasting(_ serverJS: URL) -> URL {
        guard var source = try? String(contentsOf: serverJS, encoding: .utf8) else { return serverJS }
        let original = source
        for patch in castingPatches where source.contains(patch.original) {
            source = source.replacingOccurrences(of: patch.original, with: patch.patched)
        }
        guard source != original else { return serverJS }
        let destination = Storage.url("server-lumen.js")
        if (try? String(contentsOf: destination, encoding: .utf8)) != source {
            do {
                try source.write(to: destination, atomically: true, encoding: .utf8)
            } catch {
                Log.error("Couldn't write patched server.js: \(error.localizedDescription)")
                return serverJS
            }
        }
        return destination
    }

    // MARK: Server API

    struct ServerSettings: Sendable {
        var values: [String: JSONValue]
        var options: [Option]

        struct Option: Identifiable, Sendable {
            var id: String
            var label: String
            var type: String
            var selections: [(name: String, value: JSONValue)]
        }
    }

    func fetchSettings() async throws -> ServerSettings {
        let (data, _) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("settings"))
        let json = try JSON.decoder.decode(JSONValue.self, from: data)
        var values: [String: JSONValue] = [:]
        if case .object(let dict)? = json["values"] { values = dict }
        var options: [ServerSettings.Option] = []
        if case .array(let list)? = json["options"] {
            for option in list {
                guard let id = option["id"]?.stringValue else { continue }
                var selections: [(String, JSONValue)] = []
                if case .array(let sel)? = option["selections"] {
                    for s in sel { selections.append((s["name"]?.stringValue ?? "", s["val"] ?? .null)) }
                }
                options.append(.init(id: id, label: option["label"]?.stringValue ?? id,
                                     type: option["type"]?.stringValue ?? "", selections: selections))
            }
        }
        return ServerSettings(values: values, options: options)
    }

    func updateSettings(_ values: [String: JSONValue]) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("settings"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(values)
        _ = try await URLSession.shared.data(for: request)
    }

    /// Resolves a playable HTTP URL for a stream (torrents, YouTube, proxied URLs).
    func playableURL(for stream: Stream, season: Int?, episode: Int?) async throws -> URL {
        switch stream.source {
        case .url(let url):
            if url.scheme == "magnet", let torrent = Stream.fromMagnet(url) {
                return try await playableURL(for: torrent, season: season, episode: episode)
            }
            if let headers = stream.behaviorHints.proxyHeaders, status.isRunning {
                return proxiedURL(url, headers: headers) ?? url
            }
            return url
        case let .torrent(hash, fileIdx, announce, mustInclude):
            guard status.isRunning else { throw ServerError.notRunning }
            return try await createTorrent(infoHash: hash, fileIdx: fileIdx, announce: announce,
                                           fileMustInclude: mustInclude, season: season, episode: episode)
        case .youTube(let id):
            guard status.isRunning else { throw ServerError.notRunning }
            return baseURL.appendingPathComponent("yt").appendingPathComponent(id)
        case .external(let url), .playerFrame(let url):
            return url
        case .unsupported:
            throw ServerError.unsupported
        }
    }

    enum ServerError: LocalizedError {
        case notRunning
        case unsupported

        var errorDescription: String? {
            switch self {
            case .notRunning: return "The streaming server isn't running. Torrent and YouTube streams need it."
            case .unsupported: return "This stream type isn't supported yet."
            }
        }
    }

    /// Port of stremio-video's `createTorrent`: registers the torrent with the engine and
    /// lets the server guess the file index for episodes when the addon didn't provide one.
    private func createTorrent(infoHash: String, fileIdx: Int?, announce: [String], fileMustInclude: [String],
                               season: Int?, episode: Int?) async throws -> URL {
        let sources = (["dht:\(infoHash)"] + announce.map { $0.hasPrefix("tracker:") || $0.hasPrefix("dht:") ? $0 : "tracker:\($0)" })
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        var resolvedIdx = fileIdx

        if !announce.isEmpty || fileIdx == nil {
            var body: [String: Any] = ["torrent": ["infoHash": infoHash]]
            if !announce.isEmpty {
                body["peerSearch"] = ["sources": sources, "min": 40, "max": 200]
            }
            if fileIdx == nil {
                var guess: [String: Any] = [:]
                if let season { guess["season"] = season }
                if let episode { guess["episode"] = episode }
                body["guessFileIdx"] = guess
            } else {
                body["guessFileIdx"] = false
            }
            var request = URLRequest(url: baseURL.appendingPathComponent(infoHash).appendingPathComponent("create"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.timeoutInterval = 60
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            if fileIdx == nil,
               let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let guessed = json["guessedFileIdx"] as? Int {
                resolvedIdx = guessed
            }
        }

        var components = URLComponents(url: baseURL.appendingPathComponent(infoHash).appendingPathComponent(String(resolvedIdx ?? -1)),
                                       resolvingAgainstBaseURL: false)!
        var query = announce.isEmpty ? [] : sources.map { URLQueryItem(name: "tr", value: $0) }
        query += fileMustInclude.map { URLQueryItem(name: "f", value: $0) }
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }

    private func proxiedURL(_ url: URL, headers: Stream.ProxyHeaders) -> URL? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        let origin = "\(scheme)://\(host)\(url.port.map { ":\($0)" } ?? "")"
        var items = [URLQueryItem(name: "d", value: origin)]
        items += headers.request.map { URLQueryItem(name: "h", value: "\($0.key):\($0.value)") }
        items += headers.response.map { URLQueryItem(name: "r", value: "\($0.key):\($0.value)") }
        var form = URLComponents()
        form.queryItems = items
        let encodedQuery = form.percentEncodedQuery ?? ""
        let path = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        var string = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        string += "/proxy/\(encodedQuery)/\(path)"
        if let query = url.query { string += "?\(query)" }
        return URL(string: string)
    }

    func stats(for url: URL) async -> TorrentStats? {
        // Torrent stream URLs look like {server}/{infoHash}/{fileIdx}.
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2, parts[0].count == 40 else { return nil }
        let statsURL = baseURL.appendingPathComponent(parts[0]).appendingPathComponent(parts[1]).appendingPathComponent("stats.json")
        guard let (data, _) = try? await URLSession.shared.data(from: statsURL) else { return nil }
        return try? JSONDecoder().decode(TorrentStats.self, from: data)
    }

    /// OpenSubtitles hash for a media URL (lets subtitle addons match exact releases).
    func opensubHash(for mediaURL: URL) async -> (hash: String, size: Int64)? {
        guard status.isRunning else { return nil }
        var components = URLComponents(url: baseURL.appendingPathComponent("opensubHash"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "videoUrl", value: mediaURL.absoluteString)]
        guard let url = components.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let hash = result["hash"] as? String else { return nil }
        let size = (result["size"] as? NSNumber)?.int64Value ?? 0
        return (hash, size)
    }

    // MARK: Casting

    /// A Chromecast or DLNA renderer found by the server's discovery (mDNS/SSDP at server start).
    struct CastDevice: Identifiable, Hashable, Decodable, Sendable {
        var id: String
        var name: String
        var type: String

        var isChromecast: Bool { type == "chromecast" }
    }

    struct CastError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    func castDevices() async throws -> [CastDevice] {
        let (data, _) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("casting/"))
        // "external" entries are desktop players (VLC) the server would launch locally.
        return try JSONDecoder().decode([CastDevice].self, from: data).filter { $0.type == "chromecast" || $0.type == "tv" }
    }

    /// Sends a command to a cast device and returns its media status. An empty `params` just
    /// reads the status. Times are in milliseconds, volume is 0...1.
    func castCommand(_ deviceID: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        let url = baseURL.appendingPathComponent("casting").appendingPathComponent(deviceID).appendingPathComponent("player")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(params)
        // Loading a stream probes it with ffmpeg first, which can take a while for torrents, and
        // slow TVs can take up to the server's 30s per message to answer.
        request.timeoutInterval = params["source"] == nil ? 45 : 120
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSON.decoder.decode(JSONValue.self, from: data)) ?? .null
        guard status == 200 else {
            let message = json["error"]?.stringValue ?? String(data: data, encoding: .utf8) ?? ""
            throw CastError(message: message.isEmpty ? "The device didn't respond (HTTP \(status))." : message)
        }
        return json
    }

    /// The server can convert SRT/VTT subtitles to a format mpv/AVPlayer handle reliably
    /// (and fix encodings); used for addon subtitles.
    func subtitlesURL(for subtitle: URL) -> URL {
        guard status.isRunning else { return subtitle }
        var components = URLComponents(url: baseURL.appendingPathComponent("subtitles.vtt"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "from", value: subtitle.absoluteString)]
        return components.url ?? subtitle
    }
}
