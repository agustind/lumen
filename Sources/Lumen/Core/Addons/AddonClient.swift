import Foundation

enum AddonError: LocalizedError {
    case invalidURL(String)
    case badStatus(Int)
    case legacyProtocol

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "Invalid addon URL: \(url)"
        case .badStatus(let code): return "Addon responded with HTTP \(code)"
        case .legacyProtocol: return "This addon uses the legacy v1 protocol, which isn't supported."
        }
    }
}

/// Implements the Stremio addon HTTP transport (`/{resource}/{type}/{id}[/{extra}].json`).
actor AddonClient {
    static let shared = AddonClient()

    private let session: URLSession
    private var cache: [URL: (date: Date, data: Data)] = [:]
    private var inFlight: [URL: Task<Data, Error>] = [:]
    private let cacheTTL: TimeInterval = 10 * 60

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.httpAdditionalHeaders = ["User-Agent": "Lumen-macOS/1.0"]
        session = URLSession(configuration: configuration)
    }

    /// Percent-encodes like JavaScript's `encodeURIComponent`, which addons expect.
    static func encodeComponent(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func resourceURL(addon: AddonDescriptor, resource: String, type: String, id: String, extra: [(String, String)] = []) throws -> URL {
        guard !addon.isLegacy else { throw AddonError.legacyProtocol }
        guard let base = addon.baseURL else { throw AddonError.invalidURL(addon.transportUrl) }
        var path = "/\(encodeComponent(resource))/\(encodeComponent(type))/\(encodeComponent(id))"
        if !extra.isEmpty {
            path += "/" + extra.map { "\(encodeComponent($0.0))=\(encodeComponent($0.1))" }.joined(separator: "&")
        }
        path += ".json"
        guard let url = URL(string: base.absoluteString + path) else { throw AddonError.invalidURL(base.absoluteString + path) }
        return url
    }

    func get<T: Decodable>(_ type: T.Type, addon: AddonDescriptor, resource: String, contentType: String, id: String,
                           extra: [(String, String)] = [], useCache: Bool = true) async throws -> T {
        let url = try Self.resourceURL(addon: addon, resource: resource, type: contentType, id: id, extra: extra)
        let data = try await fetch(url, useCache: useCache)
        return try JSON.decoder.decode(T.self, from: data)
    }

    func catalog(addon: AddonDescriptor, catalog: ManifestCatalog, extra: [(String, String)] = []) async throws -> [MetaItem] {
        try await get(CatalogResponse.self, addon: addon, resource: "catalog", contentType: catalog.type, id: catalog.id, extra: extra).metas
    }

    func meta(addon: AddonDescriptor, type: String, id: String) async throws -> MetaItem {
        try await get(MetaResponse.self, addon: addon, resource: "meta", contentType: type, id: id).meta
    }

    func streams(addon: AddonDescriptor, type: String, id: String) async throws -> [Stream] {
        try await get(StreamsResponse.self, addon: addon, resource: "stream", contentType: type, id: id, useCache: false).streams
    }

    func subtitles(addon: AddonDescriptor, type: String, id: String, extra: [(String, String)]) async throws -> [Subtitle] {
        try await get(SubtitlesResponse.self, addon: addon, resource: "subtitles", contentType: type, id: id, extra: extra).subtitles
    }

    func addonCatalog(addon: AddonDescriptor, catalog: ManifestCatalog) async throws -> [AddonDescriptor] {
        try await get(AddonCatalogResponse.self, addon: addon, resource: "addon_catalog", contentType: catalog.type, id: catalog.id).addons
    }

    /// Fetches and validates a manifest, returning a descriptor ready to install.
    func fetchManifest(transportUrl: String) async throws -> AddonDescriptor {
        var normalized = transportUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("stremio://") { normalized = "https://" + normalized.dropFirst("stremio://".count) }
        if normalized.hasSuffix("/stremio/v1") || normalized.hasSuffix("/stremio/v1/") { throw AddonError.legacyProtocol }
        guard let url = URL(string: normalized), url.scheme?.hasPrefix("http") == true else {
            throw AddonError.invalidURL(transportUrl)
        }
        let data = try await fetch(url, useCache: false)
        let manifest = try JSON.decoder.decode(Manifest.self, from: data)
        return AddonDescriptor(manifest: manifest, transportUrl: normalized)
    }

    func clearCache() {
        cache.removeAll()
    }

    private func fetch(_ url: URL, useCache: Bool) async throws -> Data {
        if useCache, let entry = cache[url], Date().timeIntervalSince(entry.date) < cacheTTL {
            return entry.data
        }
        if let task = inFlight[url] { return try await task.value }
        let session = self.session
        let task = Task<Data, Error> {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw AddonError.badStatus(http.statusCode)
            }
            return data
        }
        inFlight[url] = task
        defer { inFlight[url] = nil }
        let data = try await task.value
        if useCache { cache[url] = (Date(), data) }
        return data
    }
}
