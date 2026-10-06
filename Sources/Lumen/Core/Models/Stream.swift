import Foundation

struct Stream: Codable, Hashable, Identifiable, Sendable {
    enum Source: Hashable, Sendable {
        case url(URL)
        case torrent(infoHash: String, fileIdx: Int?, announce: [String], fileMustInclude: [String])
        case youTube(id: String)
        case external(URL)
        case playerFrame(URL)
        case unsupported(String)
    }

    var source: Source
    var name: String?
    var description: String?
    var thumbnail: URL?
    var subtitles: [Subtitle] = []
    var behaviorHints = BehaviorHints()
    /// The stream as received, so it can be persisted and replayed verbatim.
    var raw: JSONValue?

    struct BehaviorHints: Hashable, Sendable {
        var notWebReady = false
        var bingeGroup: String?
        var countryWhitelist: [String]?
        var proxyHeaders: ProxyHeaders?
        var filename: String?
        var videoHash: String?
        var videoSize: Int64?
    }

    struct ProxyHeaders: Hashable, Sendable {
        var request: [String: String] = [:]
        var response: [String: String] = [:]
    }

    var id: String {
        switch source {
        case .url(let url): return "url:" + url.absoluteString
        case let .torrent(hash, idx, _, _): return "bt:\(hash):\(idx.map(String.init) ?? "-")"
        case .youTube(let id): return "yt:" + id
        case .external(let url): return "ext:" + url.absoluteString
        case .playerFrame(let url): return "frame:" + url.absoluteString
        case .unsupported(let kind): return "unsupported:\(kind):\(name ?? ""):\(description ?? "")"
        }
    }

    init(source: Source, name: String? = nil, description: String? = nil) {
        self.source = source
        self.name = name
        self.description = description
    }

    private enum CodingKeys: String, CodingKey {
        case url, ytId, infoHash, fileIdx, announce, sources, fileMustInclude, externalUrl, playerFrameUrl
        case rarUrls, zipUrls, nzbUrl, tgzUrls, tarUrls
        case name, title, description, thumbnail, subtitles, behaviorHints
    }

    private enum HintKeys: String, CodingKey {
        case notWebReady, bingeGroup, countryWhitelist, proxyHeaders, filename, videoHash, videoSize
    }

    private enum ProxyKeys: String, CodingKey { case request, response }

    init(from decoder: Decoder) throws {
        raw = try? JSONValue(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let url = c.lossyURL(.url) {
            source = .url(url)
        } else if let ytId = c.lossy(String.self, .ytId) {
            source = .youTube(id: ytId)
        } else if let hash = c.lossy(String.self, .infoHash), hash.count == 40 {
            source = .torrent(
                infoHash: hash.lowercased(),
                fileIdx: c.lossyInt(.fileIdx),
                announce: c.lossy([String].self, .announce) ?? c.lossy([String].self, .sources) ?? [],
                fileMustInclude: c.lossy([String].self, .fileMustInclude) ?? []
            )
        } else if let url = c.lossyURL(.externalUrl) {
            source = .external(url)
        } else if let url = c.lossyURL(.playerFrameUrl) {
            source = .playerFrame(url)
        } else if c.contains(.rarUrls) || c.contains(.zipUrls) || c.contains(.nzbUrl) || c.contains(.tgzUrls) || c.contains(.tarUrls) {
            source = .unsupported("archive")
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown stream source"))
        }
        name = c.lossy(String.self, .name)
        description = c.lossy(String.self, .description) ?? c.lossy(String.self, .title)
        thumbnail = c.lossyURL(.thumbnail)
        subtitles = c.lossyArray(Subtitle.self, .subtitles)
        if let h = try? c.nestedContainer(keyedBy: HintKeys.self, forKey: .behaviorHints) {
            behaviorHints.notWebReady = h.lossy(Bool.self, .notWebReady) ?? false
            behaviorHints.bingeGroup = h.lossy(String.self, .bingeGroup)
            behaviorHints.countryWhitelist = h.lossy([String].self, .countryWhitelist)
            behaviorHints.filename = h.lossy(String.self, .filename)
            behaviorHints.videoHash = h.lossy(String.self, .videoHash)
            behaviorHints.videoSize = h.lossy(Int64.self, .videoSize)
            if let p = try? h.nestedContainer(keyedBy: ProxyKeys.self, forKey: .proxyHeaders) {
                behaviorHints.proxyHeaders = ProxyHeaders(
                    request: p.lossy([String: String].self, .request) ?? [:],
                    response: p.lossy([String: String].self, .response) ?? [:]
                )
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        if let raw {
            try raw.encode(to: encoder)
            return
        }
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch source {
        case .url(let url): try c.encode(url, forKey: .url)
        case let .torrent(hash, idx, announce, mustInclude):
            try c.encode(hash, forKey: .infoHash)
            try c.encodeIfPresent(idx, forKey: .fileIdx)
            if !announce.isEmpty { try c.encode(announce, forKey: .announce) }
            if !mustInclude.isEmpty { try c.encode(mustInclude, forKey: .fileMustInclude) }
        case .youTube(let id): try c.encode(id, forKey: .ytId)
        case .external(let url): try c.encode(url, forKey: .externalUrl)
        case .playerFrame(let url): try c.encode(url, forKey: .playerFrameUrl)
        case .unsupported: break
        }
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(description, forKey: .description)
    }

    static func == (lhs: Stream, rhs: Stream) -> Bool { lhs.id == rhs.id && lhs.name == rhs.name && lhs.description == rhs.description }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    // MARK: Presentation

    var isTorrent: Bool {
        if case .torrent = source { return true }
        return false
    }

    var isPlayableInApp: Bool {
        switch source {
        case .url(let url): return url.scheme != "magnet"
        case .torrent, .youTube: return true
        case .external, .playerFrame, .unsupported: return false
        }
    }

    /// The first line shown in stream lists (addon-provided name, e.g. "Torrentio\n4K").
    var displayName: String { name ?? "" }

    var displayDescription: String { description ?? behaviorHints.filename ?? "" }

    /// The description split around its stats line (Torrentio-style "👤 seeders 💾 size ⚙️ source"),
    /// so lists can keep the stats visible however long the release name is.
    struct DescriptionParts: Equatable {
        /// Release name and file name lines, before the stats line (the whole description if there is none).
        var title: String
        var stats: String?
        /// Lines after the stats line, usually languages ("🇬🇧 / 🇮🇹").
        var extra: String?
    }

    private static let statsMarkers = ["👤", "💾", "⚙️", "🌱", "📦"]

    var descriptionParts: DescriptionParts {
        let lines = displayDescription.split(whereSeparator: \.isNewline).map(String.init)
        guard let index = lines.firstIndex(where: { line in Self.statsMarkers.contains { line.contains($0) } }) else {
            return DescriptionParts(title: displayDescription)
        }
        let after = lines[(index + 1)...].joined(separator: " ")
        return DescriptionParts(title: lines[..<index].joined(separator: "\n"), stats: lines[index],
                                extra: after.isEmpty ? nil : after)
    }

    /// Magnet link for torrent streams.
    var magnetURL: URL? {
        guard case let .torrent(hash, _, announce, _) = source else { return nil }
        var components = URLComponents()
        components.scheme = "magnet"
        var items = [URLQueryItem(name: "xt", value: "urn:btih:\(hash)")]
        if let name { items.insert(URLQueryItem(name: "dn", value: name), at: 0) }
        items += announce
            .filter { $0.hasPrefix("tracker:") || !$0.contains(":") || $0.contains("://") }
            .map { URLQueryItem(name: "tr", value: $0.replacingOccurrences(of: "tracker:", with: "")) }
        components.queryItems = items
        return components.url
    }

    /// Parses `magnet:` links into a torrent stream.
    static func fromMagnet(_ url: URL) -> Stream? {
        guard url.scheme == "magnet", let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems ?? []
        guard let xt = items.first(where: { $0.name == "xt" })?.value,
              xt.lowercased().hasPrefix("urn:btih:") else { return nil }
        let hash = String(xt.dropFirst("urn:btih:".count)).lowercased()
        guard hash.count == 40 else { return nil }
        let trackers = items.filter { $0.name == "tr" }.compactMap(\.value).map { "tracker:" + $0 }
        var stream = Stream(source: .torrent(infoHash: hash, fileIdx: nil, announce: trackers, fileMustInclude: []))
        stream.name = items.first(where: { $0.name == "dn" })?.value
        return stream
    }
}

struct Subtitle: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var url: URL
    var lang: String
    var label: String?

    init(id: String, url: URL, lang: String, label: String? = nil) {
        self.id = id
        self.url = url
        self.lang = lang
        self.label = label
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let url = c.lossyURL(.url) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Subtitle without url"))
        }
        self.url = url
        id = c.lossyString(.id) ?? url.absoluteString
        lang = c.lossy(String.self, .lang) ?? "und"
        label = c.lossy(String.self, .label)
    }
}

/// Response envelopes of the addon protocol.
struct CatalogResponse: Decodable { var metas: [MetaItem] }
struct MetaResponse: Decodable { var meta: MetaItem }
struct StreamsResponse: Decodable { var streams: [Stream] }
struct SubtitlesResponse: Decodable { var subtitles: [Subtitle] }
struct AddonCatalogResponse: Decodable { var addons: [AddonDescriptor] }

extension CatalogResponse {
    private enum CodingKeys: String, CodingKey { case metas, metasDetailed }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        metas = c.lossyArray(MetaItem.self, .metas)
    }
}

extension StreamsResponse {
    private enum CodingKeys: String, CodingKey { case streams }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        streams = c.lossyArray(Stream.self, .streams)
    }
}

extension SubtitlesResponse {
    private enum CodingKeys: String, CodingKey { case subtitles }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subtitles = c.lossyArray(Subtitle.self, .subtitles)
    }
}

extension AddonCatalogResponse {
    private enum CodingKeys: String, CodingKey { case addons }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        addons = c.lossyArray(AddonDescriptor.self, .addons)
    }
}
