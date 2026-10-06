import Foundation

/// Client for TMDB recommendations (`https://api.themoviedb.org/3`). The credential is added to the
/// app's Info.plist at build time (`TMDB_TOKEN`, see scripts/build-app.sh); without it the client is off.
actor TMDBClient {
    static let shared = TMDBClient()

    /// TMDB's "API Read Access Token" (v4, sent as a bearer token) or a v3 API key.
    nonisolated static var credential: String? {
        let value = (Bundle.main.object(forInfoDictionaryKey: "LumenTMDBToken") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    nonisolated static var isConfigured: Bool { credential != nil }

    struct Result: Decodable, Sendable {
        var id: Int
        var title: String?
        var name: String?
        var posterPath: String?
        var releaseDate: String?
        var firstAirDate: String?

        private enum CodingKeys: String, CodingKey {
            case id, title, name
            case posterPath = "poster_path"
            case releaseDate = "release_date"
            case firstAirDate = "first_air_date"
        }
    }

    private struct Page: Decodable { var results: [Result] }
    private struct ExternalIds: Decodable {
        var imdbId: String?
        private enum CodingKeys: String, CodingKey { case imdbId = "imdb_id" }
    }
    private struct FindResponse: Decodable {
        var movieResults: [Result]
        var tvResults: [Result]
        private enum CodingKeys: String, CodingKey { case movieResults = "movie_results", tvResults = "tv_results" }
    }

    private let baseURL = URL(string: "https://api.themoviedb.org/3/")!
    private let session: URLSession
    /// TMDB → IMDb ids ("movie/603" → "tt0133093"); they never change.
    private var imdbIds: [String: String] = [:]
    private var cache: [String: [MetaItem]] = [:]

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration)
    }

    /// Recommendations for a Cinemeta movie or series, as items with IMDb ids so they open like any other title.
    func recommendations(for meta: MetaItem, limit: Int = 12) async throws -> [MetaItem] {
        guard meta.type == "movie" || meta.type == "series" else { return [] }
        let kind = meta.type == "series" ? "tv" : "movie"
        if let cached = cache[meta.id] { return cached }
        var tmdbId = meta.moviedbId
        if tmdbId == nil {
            tmdbId = try await findId(imdbId: meta.id, kind: kind)
        }
        guard let tmdbId else { return [] }

        let page: Page = try await get("\(kind)/\(tmdbId)/recommendations")
        let results = Array(page.results.filter { $0.posterPath != nil }.prefix(limit))
        // TMDB results don't carry IMDb ids, which Lumen's detail pages (and Cinemeta) use.
        let resolved = await withTaskGroup(of: (Int, MetaItem?).self) { group in
            for (index, result) in results.enumerated() {
                group.addTask {
                    guard let imdbId = await self.imdbId(kind: kind, tmdbId: result.id) else { return (index, nil) }
                    return (index, Self.metaItem(from: result, imdbId: imdbId, type: meta.type))
                }
            }
            var items: [(Int, MetaItem)] = []
            for await (index, item) in group {
                if let item { items.append((index, item)) }
            }
            return items.sorted { $0.0 < $1.0 }.map(\.1)
        }
        let items = resolved.filter { $0.id != meta.id }
        // Don't cache an empty result: it's more likely a transient failure (e.g. rate limiting).
        if !items.isEmpty { cache[meta.id] = items }
        return items
    }

    static func metaItem(from result: Result, imdbId: String, type: String) -> MetaItem {
        let poster = result.posterPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w342\($0)") }
        var item = MetaItem(id: imdbId, type: type, name: result.title ?? result.name ?? "", poster: poster)
        item.releaseInfo = (result.releaseDate ?? result.firstAirDate).flatMap { $0.count >= 4 ? String($0.prefix(4)) : nil }
        return item
    }

    private func imdbId(kind: String, tmdbId: Int) async -> String? {
        let key = "\(kind)/\(tmdbId)"
        if let cached = imdbIds[key] { return cached }
        guard let ids: ExternalIds = try? await get("\(key)/external_ids"),
              let imdbId = ids.imdbId, imdbId.hasPrefix("tt") else { return nil }
        imdbIds[key] = imdbId
        return imdbId
    }

    private func findId(imdbId: String, kind: String) async throws -> Int? {
        let response: FindResponse = try await get("find/\(imdbId)", query: [URLQueryItem(name: "external_source", value: "imdb_id")])
        return (kind == "tv" ? response.tvResults : response.movieResults).first?.id
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        guard let credential = Self.credential,
              var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        else { throw URLError(.userAuthenticationRequired) }
        var items = query
        // v3 API keys are 32 hex characters and go in the query; v4 read tokens are bearer tokens.
        let isV3Key = credential.count == 32 && credential.allSatisfy(\.isHexDigit)
        if isV3Key { items.append(URLQueryItem(name: "api_key", value: credential)) }
        if !items.isEmpty { components.queryItems = items }
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !isV3Key { request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AddonError.badStatus(http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
