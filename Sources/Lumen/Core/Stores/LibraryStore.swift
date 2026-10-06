import Foundation
import Observation

/// The user's library and watch progress. Mirrors stremio-core's library semantics and syncs
/// with the `libraryItem` datastore when logged in.
@MainActor
@Observable
final class LibraryStore {
    /// The stream last played for an item, so "Continue watching" can resume instantly.
    struct LastStream: Codable, Hashable {
        var videoId: String
        var stream: Stream
        var addonTransportUrl: String?
        var date: Date
    }

    private struct Persisted: Codable {
        var uid: String?
        var items: [LibraryItem]
        var lastStreams: [String: LastStream]?
    }

    private(set) var items: [String: LibraryItem] = [:]
    private(set) var lastStreams: [String: LastStream] = [:]
    private(set) var isSyncing = false
    private var uid: String?
    private var pendingPush: Set<String> = []
    private var saveTask: Task<Void, Never>?
    private var pushTask: Task<Void, Never>?
    private let api = StremioAPI()
    private weak var profile: ProfileStore?
    private static let fileName = "library.json"

    init(profile: ProfileStore) {
        self.profile = profile
        if let persisted = Storage.load(Persisted.self, from: Self.fileName) {
            uid = persisted.uid
            items = Dictionary(persisted.items.map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.mtime > b.mtime ? a : b })
            lastStreams = persisted.lastStreams ?? [:]
        }
        // Library data belongs to one account; drop it if the account changed underneath us.
        if uid != profile.auth?.user.id {
            items = [:]
            lastStreams = [:]
            uid = profile.auth?.user.id
        }
    }

    // MARK: Queries

    var libraryItems: [LibraryItem] {
        items.values.filter(\.isInLibrary)
    }

    var continueWatching: [LibraryItem] {
        items.values
            .filter(\.isInContinueWatching)
            .sorted { ($0.state.lastWatched ?? $0.mtime) > ($1.state.lastWatched ?? $1.mtime) }
    }

    var types: [String] {
        Array(Set(libraryItems.map(\.type))).sorted { Self.typeOrder($0) < Self.typeOrder($1) }
    }

    static func typeOrder(_ type: String) -> (Int, String) {
        let priority = ["movie": 0, "series": 1, "channel": 2, "tv": 3]
        return (priority[type] ?? 10, type)
    }

    func item(_ id: String) -> LibraryItem? { items[id] }

    func isInLibrary(_ id: String) -> Bool { items[id]?.isInLibrary ?? false }

    func watchedBitField(for meta: MetaItem) -> WatchedBitField? {
        guard let item = items[meta.id], !meta.videos.isEmpty else { return nil }
        return item.watchedBitField(videos: meta.videos)
    }

    // MARK: Mutations

    private func commit(_ item: LibraryItem, push: Bool = true) {
        var item = item
        item.mtime = Date()
        items[item.id] = item
        scheduleSave()
        if push { schedulePush(item.id) }
    }

    func add(_ meta: MetaItem) {
        var item = items[meta.id] ?? LibraryItem(meta: meta)
        item.name = meta.name
        item.poster = meta.poster ?? item.poster
        item.posterShape = meta.posterShape
        item.type = meta.type
        item.removed = false
        item.temp = false
        commit(item)
    }

    func remove(_ id: String) {
        guard var item = items[id] else { return }
        item.removed = true
        item.temp = false
        commit(item)
    }

    func toggle(_ meta: MetaItem) {
        if isInLibrary(meta.id) { remove(meta.id) } else { add(meta) }
    }

    /// Removes an item from "Continue watching" without touching its library membership.
    func dismissFromContinueWatching(_ id: String) {
        guard var item = items[id] else { return }
        item.state.timeOffset = 0
        commit(item)
    }

    func markWatched(_ meta: MetaItem, watched: Bool) {
        var item = items[meta.id] ?? LibraryItem(meta: meta)
        if watched {
            item.state.timesWatched += 1
            item.state.lastWatched = Date()
            item.state.timeOffset = 0
            if !meta.videos.isEmpty {
                var field = item.watchedBitField(videos: meta.videos)
                for video in meta.videos where video.isReleased { field.setVideo(video.id, watched: true) }
                item.state.watched = field.serialize()
            }
        } else {
            item.state.timesWatched = 0
            item.state.flaggedWatched = 0
            if !meta.videos.isEmpty {
                item.state.watched = WatchedBitField(videoIds: WatchedBitField.orderedVideoIds(meta.videos)).serialize()
            }
        }
        if item.temp && item.state.timesWatched == 0 { item.removed = true }
        commit(item)
    }

    func markVideos(_ videos: [Video], of meta: MetaItem, watched: Bool) {
        var item = items[meta.id] ?? LibraryItem(meta: meta)
        var field = item.watchedBitField(videos: meta.videos)
        for video in videos { field.setVideo(video.id, watched: watched) }
        item.state.watched = field.serialize()
        if watched, let latest = videos.compactMap(\.released).max() {
            if item.state.lastWatched.map({ $0 < latest }) ?? true { item.state.lastWatched = latest }
        }
        commit(item)
    }

    func toggleNotifications(_ id: String) {
        guard var item = items[id] else { return }
        item.state.noNotif.toggle()
        commit(item)
    }

    // MARK: Playback progress (port of stremio-core's Player TimeChanged handling)

    /// Ensures an item exists before playback; new items are temporary until watched or added.
    func beginPlayback(meta: MetaItem, videoId: String, stream: Stream, addonTransportUrl: String?) {
        var item = items[meta.id] ?? LibraryItem(meta: meta)
        if item.removed { item.temp = true }
        item.name = meta.name
        item.poster = meta.poster ?? item.poster
        item.state.lastWatched = Date()
        if item.state.videoId != videoId {
            item.state.videoId = videoId
            item.state.overallTimeWatched += item.state.timeWatched
            item.state.timeWatched = 0
            item.state.flaggedWatched = 0
            item.state.timeOffset = 0
        }
        lastStreams[meta.id] = LastStream(videoId: videoId, stream: stream, addonTransportUrl: addonTransportUrl, date: Date())
        commit(item)
    }

    /// Records playback position. `time` and `duration` are in milliseconds.
    /// Returns true when this update crossed the "watched" threshold.
    @discardableResult
    func updateProgress(metaId: String, videos: [Video], videoId: String, time: Int64, duration: Int64, seeked: Bool) -> Bool {
        guard var item = items[metaId] else { return false }
        item.state.lastWatched = Date()
        if item.state.videoId != videoId {
            item.state.videoId = videoId
            item.state.overallTimeWatched += item.state.timeWatched
            item.state.timeWatched = 0
            item.state.flaggedWatched = 0
        } else if !seeked {
            let delta = max(0, time - item.state.timeOffset)
            // Ignore jumps that are clearly seeks rather than playback.
            if delta < 30_000 {
                item.state.timeWatched += delta
                item.state.overallTimeWatched += delta
            }
        }
        if seeked || time > item.state.timeOffset {
            item.state.timeOffset = time
        }
        if duration > 0 { item.state.duration = duration }

        var crossedThreshold = false
        if !item.isLive, item.state.flaggedWatched == 0, item.state.duration > 0,
           Double(item.state.timeWatched) > Double(item.state.duration) * 0.7 {
            item.state.flaggedWatched = 1
            item.state.timesWatched += 1
            if !videos.isEmpty {
                var field = item.watchedBitField(videos: videos)
                field.setVideo(videoId, watched: true)
                item.state.watched = field.serialize()
            }
            crossedThreshold = true
        }
        if item.temp && item.state.timesWatched == 0 { item.removed = true }
        if item.removed { item.temp = true }

        items[metaId] = item
        items[metaId]?.mtime = Date()
        scheduleSave()
        // Progress is pushed lazily (on pause/stop) to avoid hammering the API.
        pendingPush.insert(metaId)
        return crossedThreshold
    }

    /// Called when playback ends naturally or the next episode starts.
    func finishVideo(metaId: String) {
        guard var item = items[metaId] else { return }
        item.state.timeOffset = 0
        commit(item)
    }

    func flushProgress() {
        guard !pendingPush.isEmpty else { return }
        schedulePush(nil, delay: 0)
    }

    // MARK: Persistence & sync

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        Storage.save(Persisted(uid: uid, items: Array(items.values), lastStreams: lastStreams), to: Self.fileName)
    }

    private func schedulePush(_ id: String?, delay: Double = 2) {
        if let id { pendingPush.insert(id) }
        guard profile?.auth != nil else { pendingPush.removeAll(); return }
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            await self?.pushPending()
        }
    }

    private func pushPending() async {
        guard let key = profile?.auth?.key, !pendingPush.isEmpty else { return }
        let ids = pendingPush
        pendingPush.removeAll()
        let changes = ids.compactMap { items[$0] }.filter { $0.type != "other" }
        do {
            try await api.datastorePut(authKey: key, changes: changes)
        } catch {
            Log.error("datastorePut failed: \(error)")
            pendingPush.formUnion(ids)
        }
    }

    /// Called when the account changes (login/logout).
    func resetForAccount(_ userId: String?) {
        uid = userId
        items = [:]
        lastStreams = [:]
        pendingPush = []
        saveNow()
    }

    /// Two-way sync based on modification times, like stremio-core's `LibrarySyncWithAPI`.
    func sync() async {
        guard let key = profile?.auth?.key, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let remote = try await api.datastoreMeta(authKey: key)
            let yearAgo = Date().addingTimeInterval(-365 * 24 * 3600)
            let pullIds = remote.compactMap { id, mtime -> String? in
                guard let local = items[id] else { return id }
                return mtime > local.mtime.addingTimeInterval(0.001) ? id : nil
            }
            let pushItems = items.values.filter { item in
                guard item.type != "other", !item.removed || item.mtime > yearAgo else { return false }
                guard let remoteMtime = remote[item.id] else { return true }
                return item.mtime > remoteMtime.addingTimeInterval(0.001)
            }
            if !pullIds.isEmpty {
                // Large libraries are fetched in chunks to keep requests reasonable.
                for chunk in stride(from: 0, to: pullIds.count, by: 500).map({ Array(pullIds[$0..<min($0 + 500, pullIds.count)]) }) {
                    let pulled = try await api.datastoreGet(authKey: key, ids: chunk)
                    for item in pulled { items[item.id] = item }
                }
            }
            if !pushItems.isEmpty {
                try await api.datastorePut(authKey: key, changes: Array(pushItems))
            }
            saveNow()
            Log.info("Library sync: pulled \(pullIds.count), pushed \(pushItems.count)")
        } catch {
            Log.error("Library sync failed: \(error)")
        }
    }
}
