import Foundation

enum PosterShape: String, Codable, Hashable, Sendable {
    case poster, square, landscape

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? "poster"
        self = PosterShape(rawValue: raw) ?? .poster
    }

    /// Width / height.
    var aspectRatio: CGFloat {
        switch self {
        case .poster: return 2.0 / 3.0
        case .square: return 1
        case .landscape: return 16.0 / 9.0
        }
    }
}

/// A catalog entry or a full meta object (`/meta/...` responses fill in the detail fields).
struct MetaItem: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var type: String
    var name: String
    var poster: URL?
    var posterShape: PosterShape = .poster
    var background: URL?
    var logo: URL?
    var description: String?
    var releaseInfo: String?
    var runtime: String?
    var released: Date?
    var imdbRating: String?
    var genres: [String] = []
    var cast: [String] = []
    var director: [String] = []
    var writer: [String] = []
    var links: [MetaLink] = []
    var trailerStreams: [Stream] = []
    var videos: [Video] = []
    var behaviorHints: BehaviorHints = BehaviorHints()

    struct BehaviorHints: Codable, Hashable, Sendable {
        var defaultVideoId: String?
        var featuredVideoId: String?
        var hasScheduledVideos: Bool?

        init(defaultVideoId: String? = nil, featuredVideoId: String? = nil, hasScheduledVideos: Bool? = nil) {
            self.defaultVideoId = defaultVideoId
            self.featuredVideoId = featuredVideoId
            self.hasScheduledVideos = hasScheduledVideos
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            defaultVideoId = c.lossy(String.self, .defaultVideoId)
            featuredVideoId = c.lossy(String.self, .featuredVideoId)
            hasScheduledVideos = c.lossy(Bool.self, .hasScheduledVideos)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, name, poster, posterShape, background, logo, description, releaseInfo, runtime
        case released, imdbRating, genres, genre, cast, director, writer, links, trailerStreams, trailers
        case videos, behaviorHints, year
    }

    init(id: String, type: String, name: String, poster: URL? = nil, posterShape: PosterShape = .poster) {
        self.id = id
        self.type = type
        self.name = name
        self.poster = poster
        self.posterShape = posterShape
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = c.lossy(String.self, .type) ?? "other"
        name = c.lossy(String.self, .name) ?? ""
        poster = c.lossyURL(.poster)
        posterShape = c.lossy(PosterShape.self, .posterShape) ?? .poster
        background = c.lossyURL(.background)
        logo = c.lossyURL(.logo)
        description = c.lossy(String.self, .description)
        releaseInfo = c.lossyString(.releaseInfo) ?? c.lossyString(.year)
        runtime = c.lossyString(.runtime)
        released = c.lossyDate(.released)
        imdbRating = c.lossyString(.imdbRating).flatMap { $0.isEmpty ? nil : $0 }
        genres = c.lossy([String].self, .genres) ?? c.lossy([String].self, .genre) ?? []
        cast = c.lossyArray(String.self, .cast)
        director = c.lossyArray(String.self, .director)
        writer = c.lossyArray(String.self, .writer)
        links = c.lossyArray(MetaLink.self, .links)
        trailerStreams = c.lossyArray(Stream.self, .trailerStreams)
        if trailerStreams.isEmpty {
            // Legacy `trailers: [{source: ytId, type: "Trailer"}]`.
            struct LegacyTrailer: Decodable { var source: String }
            trailerStreams = c.lossyArray(LegacyTrailer.self, .trailers).map { Stream(source: .youTube(id: $0.source)) }
        }
        videos = c.lossyArray(Video.self, .videos)
        behaviorHints = c.lossy(BehaviorHints.self, .behaviorHints) ?? BehaviorHints()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(poster, forKey: .poster)
        try c.encode(posterShape, forKey: .posterShape)
        try c.encodeIfPresent(background, forKey: .background)
        try c.encodeIfPresent(logo, forKey: .logo)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(releaseInfo, forKey: .releaseInfo)
        try c.encodeIfPresent(runtime, forKey: .runtime)
        try c.encodeIfPresent(released, forKey: .released)
        try c.encodeIfPresent(imdbRating, forKey: .imdbRating)
        try c.encode(genres, forKey: .genres)
        try c.encode(links, forKey: .links)
        try c.encode(videos, forKey: .videos)
        try c.encode(behaviorHints, forKey: .behaviorHints)
    }

    // MARK: Derived

    /// Genres from `links` (current protocol) falling back to the legacy `genres` array.
    var allGenres: [String] {
        let fromLinks = links.filter { $0.category == "Genres" }.map(\.name)
        return fromLinks.isEmpty ? genres : fromLinks
    }

    var allCast: [String] {
        let fromLinks = links.filter { $0.category == "Cast" }.map(\.name)
        return fromLinks.isEmpty ? cast : fromLinks
    }

    var allDirectors: [String] {
        let fromLinks = links.filter { $0.category == "Directors" }.map(\.name)
        return fromLinks.isEmpty ? director : fromLinks
    }

    var allWriters: [String] {
        let fromLinks = links.filter { $0.category == "Writers" }.map(\.name)
        return fromLinks.isEmpty ? writer : fromLinks
    }

    var rating: String? {
        links.first { $0.category == "imdb" && !$0.name.isEmpty }?.name ?? imdbRating
    }

    var imdbURL: URL? {
        links.first { $0.category == "imdb" }?.url ?? (id.hasPrefix("tt") ? URL(string: "https://imdb.com/title/\(id)") : nil)
    }

    /// Seasons in display order, with specials (season 0) last.
    var seasons: [Int] {
        let all = Set(videos.compactMap(\.season))
        return all.filter { $0 != 0 }.sorted() + (all.contains(0) ? [0] : [])
    }

    var isSeriesLike: Bool { !videos.isEmpty && videos.contains { $0.season != nil } }

    func videos(inSeason season: Int) -> [Video] {
        videos.filter { $0.season == season }.sorted { ($0.episode ?? 0) < ($1.episode ?? 0) }
    }

    /// Videos in playback order (season/episode, then release date).
    var orderedVideos: [Video] {
        videos.sorted { a, b in
            switch (a.season, b.season) {
            case let (sa?, sb?) where sa != sb:
                if sa == 0 { return false }
                if sb == 0 { return true }
                return sa < sb
            case (.some, .some):
                return (a.episode ?? 0) < (b.episode ?? 0)
            default:
                return (a.released ?? .distantPast) < (b.released ?? .distantPast)
            }
        }
    }

    func nextVideo(after videoId: String) -> Video? {
        let ordered = orderedVideos
        guard let index = ordered.firstIndex(where: { $0.id == videoId }), index + 1 < ordered.count else { return nil }
        let next = ordered[index + 1]
        // Don't roll from the last regular season into specials.
        if let current = ordered[index].season, current != 0, next.season == 0 { return nil }
        return next
    }

    var preview: MetaItem {
        var item = MetaItem(id: id, type: type, name: name, poster: poster, posterShape: posterShape)
        item.background = background
        item.logo = logo
        item.releaseInfo = releaseInfo
        item.imdbRating = imdbRating
        item.description = description
        item.behaviorHints = behaviorHints
        return item
    }
}

struct MetaLink: Codable, Hashable, Sendable {
    var name: String
    var category: String
    var url: URL?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        category = c.lossy(String.self, .category) ?? ""
        url = c.lossyURL(.url)
    }
}

struct Video: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var released: Date?
    var thumbnail: URL?
    var season: Int?
    var episode: Int?
    var overview: String?
    var streams: [Stream] = []

    private enum CodingKeys: String, CodingKey {
        case id, title, name, released, firstAired, thumbnail, season, episode, number, overview, description, streams
    }

    init(id: String, title: String, season: Int? = nil, episode: Int? = nil) {
        self.id = id
        self.title = title
        self.season = season
        self.episode = episode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = c.lossy(String.self, .title) ?? c.lossy(String.self, .name) ?? ""
        released = c.lossyDate(.released) ?? c.lossyDate(.firstAired)
        thumbnail = c.lossyURL(.thumbnail)
        season = c.lossyInt(.season)
        episode = c.lossyInt(.episode) ?? c.lossyInt(.number)
        overview = c.lossy(String.self, .overview) ?? c.lossy(String.self, .description)
        streams = c.lossyArray(Stream.self, .streams)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(released, forKey: .released)
        try c.encodeIfPresent(thumbnail, forKey: .thumbnail)
        try c.encodeIfPresent(season, forKey: .season)
        try c.encodeIfPresent(episode, forKey: .episode)
        try c.encodeIfPresent(overview, forKey: .overview)
    }

    var isReleased: Bool { (released ?? .distantPast) <= Date() }

    var label: String {
        if let season, let episode { return "S\(season)E\(episode)" }
        return title
    }
}
