import Foundation

/// A library entry, synced with the `libraryItem` datastore collection.
/// Field names and semantics follow stremio-core so the official apps see the same state.
struct LibraryItem: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var type: String
    var poster: URL?
    var posterShape: PosterShape = .poster
    var removed: Bool
    var temp: Bool
    var ctime: Date?
    var mtime: Date
    var state: State
    var behaviorHints: JSONValue?

    struct State: Codable, Hashable, Sendable {
        var lastWatched: Date?
        /// Milliseconds.
        var timeWatched: Int64 = 0
        /// Milliseconds.
        var timeOffset: Int64 = 0
        /// Milliseconds.
        var overallTimeWatched: Int64 = 0
        var timesWatched: Int = 0
        var flaggedWatched: Int = 0
        /// Milliseconds.
        var duration: Int64 = 0
        var videoId: String?
        var watched: String?
        var noNotif: Bool = false

        private enum CodingKeys: String, CodingKey {
            case lastWatched, timeWatched, timeOffset, overallTimeWatched, timesWatched, flaggedWatched
            case duration, videoId = "video_id", watched, noNotif
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            lastWatched = c.lossyDate(.lastWatched)
            timeWatched = Int64(c.lossy(Double.self, .timeWatched) ?? 0)
            timeOffset = Int64(c.lossy(Double.self, .timeOffset) ?? 0)
            overallTimeWatched = Int64(c.lossy(Double.self, .overallTimeWatched) ?? 0)
            timesWatched = c.lossyInt(.timesWatched) ?? 0
            flaggedWatched = c.lossyInt(.flaggedWatched) ?? 0
            duration = Int64(c.lossy(Double.self, .duration) ?? 0)
            videoId = c.lossy(String.self, .videoId).flatMap { $0.isEmpty ? nil : $0 }
            watched = c.lossy(String.self, .watched).flatMap { $0.isEmpty ? nil : $0 }
            noNotif = c.lossy(Bool.self, .noNotif) ?? false
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            if let lastWatched { try c.encode(JSON.formatDate(lastWatched), forKey: .lastWatched) } else { try c.encodeNil(forKey: .lastWatched) }
            try c.encode(timeWatched, forKey: .timeWatched)
            try c.encode(timeOffset, forKey: .timeOffset)
            try c.encode(overallTimeWatched, forKey: .overallTimeWatched)
            try c.encode(timesWatched, forKey: .timesWatched)
            try c.encode(flaggedWatched, forKey: .flaggedWatched)
            try c.encode(duration, forKey: .duration)
            if let videoId { try c.encode(videoId, forKey: .videoId) } else { try c.encodeNil(forKey: .videoId) }
            if let watched { try c.encode(watched, forKey: .watched) } else { try c.encodeNil(forKey: .watched) }
            try c.encode(noNotif, forKey: .noNotif)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id = "_id", name, type, poster, posterShape, removed, temp, ctime = "_ctime", mtime = "_mtime"
        case state, behaviorHints
    }

    init(meta: MetaItem, now: Date = Date()) {
        id = meta.id
        name = meta.name
        type = meta.type
        poster = meta.poster
        posterShape = meta.posterShape
        removed = true
        temp = true
        ctime = now
        mtime = now
        state = State()
        state.lastWatched = now
        if let hints = try? JSONValue.encodeFrom(meta.behaviorHints) { behaviorHints = hints }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.lossy(String.self, .name) ?? ""
        type = c.lossy(String.self, .type) ?? "other"
        poster = c.lossyURL(.poster)
        posterShape = c.lossy(PosterShape.self, .posterShape) ?? .poster
        removed = c.lossy(Bool.self, .removed) ?? false
        temp = c.lossy(Bool.self, .temp) ?? false
        ctime = c.lossyDate(.ctime)
        mtime = c.lossyDate(.mtime) ?? Date(timeIntervalSince1970: 0)
        state = c.lossy(State.self, .state) ?? State()
        behaviorHints = c.lossy(JSONValue.self, .behaviorHints)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(type, forKey: .type)
        try c.encode(poster?.absoluteString ?? "", forKey: .poster)
        try c.encode(posterShape, forKey: .posterShape)
        try c.encode(removed, forKey: .removed)
        try c.encode(temp, forKey: .temp)
        if let ctime { try c.encode(JSON.formatDate(ctime), forKey: .ctime) } else { try c.encodeNil(forKey: .ctime) }
        try c.encode(JSON.formatDate(mtime), forKey: .mtime)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(behaviorHints, forKey: .behaviorHints)
    }

    // MARK: Derived state (mirrors stremio-core)

    /// Visible in the library (not removed, not a temporary "watched once" entry).
    var isInLibrary: Bool { !removed && type != "other" }

    var isInContinueWatching: Bool {
        type != "other" && (!removed || temp) && state.timeOffset > 0
    }

    var progress: Double {
        guard state.timeOffset > 0, state.duration > 0 else { return 0 }
        return min(1, Double(state.timeOffset) / Double(state.duration))
    }

    var isWatched: Bool { state.timesWatched > 0 }

    var defaultVideoId: String? { behaviorHints?["defaultVideoId"]?.stringValue }

    var isLive: Bool { behaviorHints?["isLive"]?.boolValue ?? (type == "tv") }

    var preview: MetaItem {
        MetaItem(id: id, type: type, name: name, poster: poster, posterShape: posterShape)
    }

    func watchedBitField(videos: [Video]) -> WatchedBitField {
        let ids = WatchedBitField.orderedVideoIds(videos)
        if let serialized = state.watched, let field = WatchedBitField(serialized: serialized, videoIds: ids) {
            return field
        }
        return WatchedBitField(videoIds: ids)
    }
}

extension JSONValue {
    static func encodeFrom<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}
