import Foundation
import Synchronization

/// Real-Debrid without installing addons. With a token in Settings, Lumen adds a built-in "Real-Debrid"
/// stream addon. `AddonClient` answers its stream requests by querying the enabled sources (hosted
/// Torrentio and Comet, configured with the token) and merging their results.
///
/// The built-in addon never joins the synced addon collection, so the token stays on this Mac
/// (in `profile.json`, like the Stremio auth key) and with the sources that need it.
enum RealDebrid {
    enum Source: String, CaseIterable, Identifiable, Sendable {
        case torrentio
        case comet

        var id: String { rawValue }

        var title: String {
            switch self {
            case .torrentio: return "Torrentio"
            case .comet: return "Comet"
            }
        }

        var detail: String {
            switch self {
            case .torrentio: return "Searches its own index of torrent sites."
            case .comet: return "Searches indexers and hash lists shared by debrid users. Often finds more cached releases."
            }
        }

        func streamURL(token: String, type: String, id: String) -> URL? {
            let path = "stream/\(AddonClient.encodeComponent(type))/\(AddonClient.encodeComponent(id)).json"
            switch self {
            case .torrentio:
                return URL(string: "https://torrentio.strem.fun/realdebrid=\(token)/\(path)")
            case .comet:
                // Comet reads its configuration as base64 JSON in the first path segment. Comet decodes it
                // as standard base64, so a "/" in the encoding would break the URL. This JSON (ASCII, with
                // a letters-and-digits token) never encodes to one.
                let json = #"{"debridServices":[{"service":"realdebrid","apiKey":"\#(token)"}],"enableTorrent":false,"deduplicateStreams":true}"#
                return URL(string: "https://comet.elfhosted.com/\(Data(json.utf8).base64EncodedString())/\(path)")
            }
        }
    }

    struct Config: Sendable {
        var token: String
        var sources: [Source]
    }

    /// Mirrors the Real-Debrid settings (kept in step by `ProfileStore`) so `AddonClient` can read them.
    private static let state = Mutex(Config(token: "", sources: []))

    static var config: Config {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }

    static func configure(_ settings: AppSettings) {
        config = Config(token: settings.realDebridToken,
                        sources: Source.allCases.filter { settings.realDebridSources.contains($0.rawValue) })
    }

    /// Real-Debrid API tokens are letters and digits.
    static func isValidToken(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    // MARK: Built-in addon

    static let transportUrl = "builtin://realdebrid"

    static func isBuiltIn(_ addon: AddonDescriptor) -> Bool { addon.transportUrl == transportUrl }

    /// The built-in stream addon, or nil when there's no token or no source is enabled.
    static func addon(for settings: AppSettings) -> AddonDescriptor? {
        guard isValidToken(settings.realDebridToken),
              Source.allCases.contains(where: { settings.realDebridSources.contains($0.rawValue) }) else { return nil }
        return builtInAddon
    }

    private static let builtInAddon: AddonDescriptor = {
        let json = #"""
        {"id":"lumen.realdebrid","version":"1.0.0","name":"Real-Debrid",
         "description":"Cached torrents through your Real-Debrid account.",
         "types":["movie","series","anime"],"idPrefixes":["tt","kitsu"],
         "resources":["stream"],"catalogs":[]}
        """#
        let manifest = try! JSON.decoder.decode(Manifest.self, from: Data(json.utf8))
        return AddonDescriptor(manifest: manifest, transportUrl: transportUrl, flags: .init(protected: true))
    }()

    // MARK: Merging

    /// Combines the sources' results: cached before uncached, then by resolution. Within that, streams
    /// keep each source's own order, interleaved. A torrent listed by several sources appears once.
    static func merge(_ lists: [[Stream]]) -> [Stream] {
        let ranked = lists.enumerated().flatMap { sourceIndex, streams in
            streams.enumerated().map { index, stream in
                (stream: stream, cached: isCached(stream), resolution: resolution(of: stream), index: index, source: sourceIndex)
            }
        }
        let sorted = ranked.sorted { a, b in
            if a.cached != b.cached { return a.cached }
            if a.resolution != b.resolution { return a.resolution > b.resolution }
            if a.index != b.index { return a.index < b.index }
            return a.source < b.source
        }
        var seen: Set<String> = []
        return sorted.map(\.stream).filter { stream in
            guard let hash = infoHash(of: stream) else { return true }
            return seen.insert(hash).inserted
        }
    }

    /// Torrent hash of a stream. Debrid sources return playback URLs with the hash as a path component.
    static func infoHash(of stream: Stream) -> String? {
        switch stream.source {
        case let .torrent(hash, _, _, _):
            return hash
        case .url(let url):
            return url.pathComponents.first { $0.count == 40 && $0.allSatisfy(\.isHexDigit) }?.lowercased()
        default:
            return nil
        }
    }

    /// Torrentio marks releases Real-Debrid already has as "[RD+]", Comet as "[RD⚡]".
    static func isCached(_ stream: Stream) -> Bool {
        let name = stream.displayName
        return name.contains("RD+") || name.contains("⚡")
    }

    static func resolution(of stream: Stream) -> Int {
        let text = "\(stream.displayName) \(stream.displayDescription)".lowercased()
        let known: [(String, Int)] = [("2160p", 2160), ("4k", 2160), ("1440p", 1440), ("1080p", 1080),
                                      ("720p", 720), ("576p", 576), ("480p", 480)]
        return known.first { text.contains($0.0) }?.1 ?? 0
    }

    // MARK: Account

    struct Account: Decodable, Sendable {
        var username: String
        var type: String
        var expiration: Date?

        var isPremium: Bool { type == "premium" }
    }

    enum AccountError: LocalizedError {
        case invalidToken
        case badStatus(Int)

        var errorDescription: String? {
            switch self {
            case .invalidToken: return "Real-Debrid didn't accept this token."
            case .badStatus(let code): return "Real-Debrid responded with HTTP \(code)."
            }
        }
    }

    /// Checks a token against the Real-Debrid API and returns the account it belongs to.
    static func account(token: String) async throws -> Account {
        guard isValidToken(token) else { throw AccountError.invalidToken }
        var request = URLRequest(url: URL(string: "https://api.real-debrid.com/rest/1.0/user")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw AccountError.invalidToken }
        guard (200..<300).contains(status) else { throw AccountError.badStatus(status) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: string) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(string)"))
        }
        return try decoder.decode(Account.self, from: data)
    }
}

extension AddonClient {
    /// Streams of the built-in Real-Debrid addon: every enabled source is queried in parallel and the
    /// results are merged. A source that fails is skipped; the request fails only if all of them do.
    func realDebridStreams(type: String, id: String) async throws -> [Stream] {
        let config = RealDebrid.config
        guard RealDebrid.isValidToken(config.token) else { return [] }
        let tasks = config.sources.map { source in
            Task { () -> Result<[Stream], Error> in
                do {
                    guard let url = source.streamURL(token: config.token, type: type, id: id) else {
                        throw AddonError.invalidURL(source.title)
                    }
                    let data = try await self.fetch(url, useCache: false)
                    return .success(try JSON.decoder.decode(StreamsResponse.self, from: data).streams)
                } catch {
                    return .failure(error)
                }
            }
        }
        var lists: [[Stream]] = []
        var lastError: Error?
        for (source, task) in zip(config.sources, tasks) {
            switch await task.value {
            case .success(let streams):
                lists.append(streams)
            case .failure(let error):
                Log.error("\(source.title) (Real-Debrid) failed: \(error)")
                lastError = error
            }
        }
        if lists.isEmpty, let lastError { throw lastError }
        return RealDebrid.merge(lists)
    }
}
