import AppKit
import Observation

/// What to play: a stream for a meta item (and optionally a specific episode).
struct PlaybackRequest: Hashable {
    var stream: Stream
    var meta: MetaItem?
    var videoId: String?
    var addonTransportUrl: String?
    /// Resume position in seconds (nil = resume from library progress when available).
    var startAt: Double?
}

/// Subtitles offered by addons for the current video.
struct AddonSubtitle: Identifiable, Hashable {
    var subtitle: Subtitle
    var addonName: String
    var id: String { "\(addonName):\(subtitle.id)" }
}

@MainActor
@Observable
final class PlayerSession: Identifiable {
    let id = UUID()
    private(set) var request: PlaybackRequest
    let engine: PlaybackEngine
    var state: PlaybackState { engine.state }

    private(set) var resolvedURL: URL?
    private(set) var resolveError: String?
    private(set) var addonSubtitles: [AddonSubtitle] = []
    /// Addon subtitle ids → engine track ids once loaded.
    private var loadedAddonSubtitles: [String: String] = [:]
    private(set) var selectedAddonSubtitleId: String?
    private(set) var torrentStats: StreamingServer.TorrentStats?
    private(set) var nextVideo: Video?
    private(set) var nextStreamCandidate: (stream: Stream, addon: AddonDescriptor)?
    var showNextEpisodePrompt = false

    enum SubtitleSyncState: Equatable {
        case idle
        case running
        case synced(offset: Double, scale: Double)
        case failed(String)
    }

    private(set) var subtitleSync: SubtitleSyncState = .idle
    private var syncTask: Task<Void, Never>?

    private let profile: ProfileStore
    private let library: LibraryStore
    private let server: StreamingServer
    private var progressTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private var lastReportedTime: Double = 0
    private var didSeekSinceReport = false
    private var autoSelectedSubtitles = false
    private var autoSelectedAudio = false
    private var nextEpisodeDismissed = false

    var title: String {
        guard let meta = request.meta else { return request.stream.name ?? "Lumen" }
        return meta.name
    }

    var subtitle: String? {
        guard let video = currentVideo else { return request.stream.displayDescription.components(separatedBy: "\n").first }
        if let season = video.season, let episode = video.episode {
            return "S\(season) E\(episode)" + (video.title.isEmpty ? "" : " · \(video.title)")
        }
        return video.title
    }

    var currentVideo: Video? {
        guard let meta = request.meta, let videoId = request.videoId else { return nil }
        return meta.videos.first { $0.id == videoId }
    }

    init(request: PlaybackRequest, profile: ProfileStore, library: LibraryStore, server: StreamingServer) {
        self.request = request
        self.profile = profile
        self.library = library
        self.server = server
        engine = PlaybackEngineFactory.make(preference: profile.settings.playerEngine,
                                            hardwareDecoding: profile.settings.hardwareDecoding)
        engine.setSubtitleScale(Double(profile.settings.subtitlesSize) / 100)
        Task { await start() }
    }

    // MARK: Lifecycle

    private func start() async {
        resolveError = nil
        resolvedURL = nil
        loadedAddonSubtitles = [:]
        selectedAddonSubtitleId = nil
        addonSubtitles = []
        autoSelectedSubtitles = false
        autoSelectedAudio = false
        nextEpisodeDismissed = false
        showNextEpisodePrompt = false
        nextStreamCandidate = nil

        let video = currentVideo
        do {
            let url = try await server.playableURL(for: request.stream, season: video?.season, episode: video?.episode)
            resolvedURL = url
            var startAt = request.startAt
            if startAt == nil, let meta = request.meta, let item = library.item(meta.id),
               item.state.videoId == (request.videoId ?? meta.id), item.state.timeOffset > 0 {
                startAt = Double(item.state.timeOffset) / 1000
            }
            if let meta = request.meta {
                library.beginPlayback(meta: meta, videoId: request.videoId ?? meta.id,
                                      stream: request.stream, addonTransportUrl: request.addonTransportUrl)
            }
            lastReportedTime = startAt ?? 0
            engine.load(url, startAt: startAt)
            startProgressReporting()
            if request.stream.isTorrent { startStatsPolling(url: url) }
            await loadAddonSubtitles(mediaURL: url)
            computeNextVideo()
        } catch {
            resolveError = error.localizedDescription
            state.isBuffering = false
        }
    }

    func close() {
        reportProgress(force: true)
        library.flushProgress()
        progressTask?.cancel()
        statsTask?.cancel()
        engine.stop()
    }

    // MARK: Controls

    func togglePause() { engine.setPaused(!state.isPaused) }

    func seek(to seconds: Double) {
        let clamped = max(0, state.duration > 0 ? min(seconds, state.duration - 1) : seconds)
        engine.seek(to: clamped)
        didSeekSinceReport = true
    }

    func seek(by delta: Double) { seek(to: state.time + delta) }

    func setVolume(_ volume: Double) { engine.setVolume(volume) }

    func toggleMute() { engine.setMuted(!state.isMuted) }

    func setSpeed(_ speed: Double) { engine.setSpeed(speed) }

    func selectAudio(_ track: MediaTrack) { engine.selectAudioTrack(track.id) }

    func selectEmbeddedSubtitle(_ track: MediaTrack?) {
        resetSubtitleTiming()
        selectedAddonSubtitleId = nil
        if let track, let addonId = loadedAddonSubtitles.first(where: { $0.value == track.id })?.key {
            selectedAddonSubtitleId = addonId
        }
        engine.selectSubtitleTrack(track?.id)
    }

    func selectAddonSubtitle(_ subtitle: AddonSubtitle) {
        if selectedAddonSubtitleId != subtitle.id { resetSubtitleTiming() }
        selectedAddonSubtitleId = subtitle.id
        if let trackId = loadedAddonSubtitles[subtitle.id] {
            engine.selectSubtitleTrack(trackId)
            return
        }
        let before = Set(state.subtitleTracks.map(\.id))
        let label = subtitle.subtitle.label ?? "\(ISOLanguage.name(for: subtitle.subtitle.lang)) (\(subtitle.addonName))"
        engine.addExternalSubtitle(url: subtitle.subtitle.url, title: label, lang: subtitle.subtitle.lang)
        // Select the new track once the engine reports it.
        Task {
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(150))
                if let track = state.subtitleTracks.first(where: { !before.contains($0.id) && $0.isExternal }) {
                    loadedAddonSubtitles[subtitle.id] = track.id
                    if selectedAddonSubtitleId == subtitle.id { engine.selectSubtitleTrack(track.id) }
                    return
                }
            }
        }
    }

    func disableSubtitles() {
        resetSubtitleTiming()
        selectedAddonSubtitleId = nil
        engine.selectSubtitleTrack(nil)
    }

    func adjustSubtitleDelay(by delta: Double) { engine.setSubtitleDelay(state.subtitleDelay + delta) }

    /// A sync computed for one subtitle doesn't apply to another.
    private func resetSubtitleTiming() {
        syncTask?.cancel()
        subtitleSync = .idle
        if state.subtitleDelay != 0 { engine.setSubtitleDelay(0) }
        if state.subtitleSpeed != 1 { engine.setSubtitleSpeed(1) }
    }

    var canAutoSyncSubtitles: Bool {
        engine.supportsExternalSubtitles && state.selectedSubtitleId != nil && resolvedURL != nil
    }

    /// Aligns the active subtitles to the dialogue around the current position.
    func autoSyncSubtitles() {
        guard canAutoSyncSubtitles, let media = resolvedURL, subtitleSync != .running else { return }
        syncTask?.cancel()
        subtitleSync = .running
        let position = state.time
        let duration = state.duration
        let addonSubtitle = addonSubtitles.first { $0.id == selectedAddonSubtitleId }
        let track = state.subtitleTracks.first { $0.id == state.selectedSubtitleId }
        let audioIndex = state.audioTracks.first { $0.id == state.selectedAudioId }?.ffIndex
        syncTask = Task {
            do {
                let result = try await Self.computeSync(media: media, position: position, duration: duration,
                                                        subtitleURL: addonSubtitle?.subtitle.url, track: track, audioIndex: audioIndex)
                try Task.checkCancellation()
                engine.setSubtitleSpeed(result.scale)
                engine.setSubtitleDelay(result.offset)
                subtitleSync = .synced(offset: result.offset, scale: result.scale)
            } catch is CancellationError {
            } catch {
                subtitleSync = .failed(error.localizedDescription)
            }
        }
    }

    nonisolated static func computeSync(media: URL, position: Double, duration: Double, subtitleURL: URL?,
                                                track: MediaTrack?, audioIndex: Int?) async throws -> SubtitleSync.Result {
        // Analyse ~6 minutes around the playhead: enough dialogue to be reliable, little to download.
        let start = max(0, position - 120)
        let length = duration > 0 ? min(360, duration - start) : 360
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-subsync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var cues: [SubtitleSync.Cue] = []
        var embeddedIndex: Int?
        if let subtitleURL {
            let (data, _) = try await URLSession.shared.data(from: subtitleURL)
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            cues = SubtitleSync.parseCues(text)
        } else if let track {
            let bitmapCodecs = ["hdmv_pgs_subtitle", "pgssub", "dvd_subtitle", "dvdsub", "dvb_subtitle", "dvbsub", "xsub"]
            guard let index = track.ffIndex, !bitmapCodecs.contains((track.codec ?? "").lowercased()) else {
                throw SubtitleSync.SyncError.unsupportedSubtitle
            }
            embeddedIndex = index
        }

        let extracted = try await SubtitleSync.extract(from: media, start: start, duration: length, audioStreamIndex: audioIndex,
                                                       subtitleStreamIndex: embeddedIndex, into: directory)
        if let subtitlesFile = extracted.subtitles {
            let text = (try? String(contentsOf: subtitlesFile, encoding: .utf8)) ?? ""
            // Extracted with input seeking, so times are relative to `start`.
            cues = SubtitleSync.parseCues(text).map { .init(start: $0.start + start, end: $0.end + start) }
        }
        guard !cues.isEmpty else { throw SubtitleSync.SyncError.notEnoughData }
        let speech = try SubtitleSync.detectSpeech(in: extracted.audio, origin: start)
        return try SubtitleSync.align(speech: speech, cues: cues)
    }

    /// Embedded (non-addon) subtitle tracks.
    var embeddedSubtitleTracks: [MediaTrack] {
        let addonTrackIds = Set(loadedAddonSubtitles.values)
        return state.subtitleTracks.filter { !addonTrackIds.contains($0.id) }
    }

    // MARK: Progress

    private func startProgressReporting() {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.tick()
            }
        }
    }

    private var lastFlush = Date()

    private func tick() {
        reportProgress(force: false)
        // Push progress to the account every 30s while playing (stremio-core uses a similar cadence).
        if Date().timeIntervalSince(lastFlush) > 30 {
            lastFlush = Date()
            library.flushProgress()
        }
        updateNextEpisodePrompt()
        if state.didReachEnd { handleEnded() }
        autoSelectTracksIfNeeded()
    }

    private func reportProgress(force: Bool) {
        guard let meta = request.meta, state.isLoaded, state.duration > 0 else { return }
        let time = state.time
        guard force || abs(time - lastReportedTime) >= 1 || didSeekSinceReport else { return }
        let seeked = didSeekSinceReport || abs(time - lastReportedTime) > 5
        didSeekSinceReport = false
        lastReportedTime = time
        let watched = library.updateProgress(
            metaId: meta.id, videos: meta.videos, videoId: request.videoId ?? meta.id,
            time: Int64(time * 1000), duration: Int64(state.duration * 1000), seeked: seeked
        )
        if watched { library.flushProgress() }
    }

    private func startStatsPolling(url: URL) {
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.torrentStats = await self.server.stats(for: url)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: Subtitles

    private func loadAddonSubtitles(mediaURL: URL) async {
        guard let meta = request.meta else { return }
        let type = meta.type
        let id = request.videoId ?? meta.id
        var extra: [(String, String)] = []
        var hash = request.stream.behaviorHints.videoHash
        var size = request.stream.behaviorHints.videoSize
        if hash == nil || size == nil, let computed = await server.opensubHash(for: mediaURL) {
            hash = hash ?? computed.hash
            size = size ?? computed.size
        }
        if let hash { extra.append(("videoHash", hash)) }
        if let size, size > 0 { extra.append(("videoSize", String(size))) }
        if let filename = request.stream.behaviorHints.filename { extra.append(("filename", filename)) }

        var results: [AddonSubtitle] = request.stream.subtitles.map { AddonSubtitle(subtitle: $0, addonName: "Stream") }
        let addons = profile.addons(supporting: "subtitles", type: type, id: id)
        let extraParams = extra
        await forEachConcurrently(addons) { addon in
            let subtitles = (try? await AddonClient.shared.subtitles(addon: addon, type: type, id: id, extra: extraParams)) ?? []
            return subtitles.map { AddonSubtitle(subtitle: $0, addonName: addon.manifest.name) }
        } onResult: { _, batch in
            results += batch
        }
        addonSubtitles = results
        autoSelectTracksIfNeeded()
    }

    /// Picks audio/subtitle tracks matching the user's language preferences once.
    private func autoSelectTracksIfNeeded() {
        guard state.isLoaded else { return }
        let settings = profile.settings

        if !autoSelectedAudio, !state.audioTracks.isEmpty {
            autoSelectedAudio = true
            if !settings.audioLanguage.isEmpty,
               let track = state.audioTracks.first(where: { ISOLanguage.normalize($0.lang ?? "") == ISOLanguage.normalize(settings.audioLanguage) }),
               track.id != state.selectedAudioId {
                engine.selectAudioTrack(track.id)
            }
        }

        guard !autoSelectedSubtitles else { return }
        let preferred = ISOLanguage.normalize(settings.subtitlesLanguage)
        guard !preferred.isEmpty else {
            autoSelectedSubtitles = true
            return
        }
        // If the audio is already in the preferred language, don't force subtitles.
        if let audio = state.audioTracks.first(where: { $0.id == state.selectedAudioId }),
           ISOLanguage.normalize(audio.lang ?? "") == preferred {
            autoSelectedSubtitles = true
            return
        }
        if let embedded = embeddedSubtitleTracks.first(where: { ISOLanguage.normalize($0.lang ?? "") == preferred }) {
            autoSelectedSubtitles = true
            engine.selectSubtitleTrack(embedded.id)
        } else if let addon = addonSubtitles.first(where: { ISOLanguage.normalize($0.subtitle.lang) == preferred }) {
            autoSelectedSubtitles = true
            selectAddonSubtitle(addon)
        }
    }

    // MARK: Next episode / binge watching

    private func computeNextVideo() {
        guard let meta = request.meta, let videoId = request.videoId else { return }
        nextVideo = meta.nextVideo(after: videoId).flatMap { $0.isReleased ? $0 : nil }
        guard let nextVideo, profile.settings.bingeWatching else { return }
        Task { await findBingeStream(for: nextVideo, meta: meta) }
    }

    /// Looks for a stream of the next episode in the same binge group from the same addon.
    private func findBingeStream(for video: Video, meta: MetaItem) async {
        guard let group = request.stream.behaviorHints.bingeGroup,
              let transportUrl = request.addonTransportUrl,
              let addon = profile.activeAddons.first(where: { $0.transportUrl == transportUrl }) else { return }
        guard let streams = try? await AddonClient.shared.streams(addon: addon, type: meta.type, id: video.id) else { return }
        if let match = streams.first(where: { $0.behaviorHints.bingeGroup == group }) {
            nextStreamCandidate = (match, addon)
        }
    }

    private func updateNextEpisodePrompt() {
        guard nextVideo != nil, !nextEpisodeDismissed, state.duration > 60 else {
            showNextEpisodePrompt = false
            return
        }
        // Show near the credits (last 5% or final 60 seconds).
        let remaining = state.duration - state.time
        showNextEpisodePrompt = remaining < max(60, state.duration * 0.05)
    }

    func dismissNextEpisodePrompt() {
        nextEpisodeDismissed = true
        showNextEpisodePrompt = false
    }

    private var handledEnd = false

    private func handleEnded() {
        guard !handledEnd else { return }
        handledEnd = true
        if let meta = request.meta { library.finishVideo(metaId: meta.id) }
        if nextStreamCandidate != nil, profile.settings.bingeWatching {
            playNext()
        }
    }

    /// Plays the next episode. Returns false if no stream could be chosen automatically
    /// (the caller should then show the stream picker).
    @discardableResult
    func playNext() -> Bool {
        guard let meta = request.meta, let nextVideo else { return false }
        guard let candidate = nextStreamCandidate else { return false }
        reportProgress(force: true)
        library.finishVideo(metaId: meta.id)
        handledEnd = false
        request = PlaybackRequest(stream: candidate.stream, meta: meta, videoId: nextVideo.id,
                                  addonTransportUrl: candidate.addon.transportUrl, startAt: nil)
        self.nextVideo = nil
        Task { await start() }
        return true
    }

    /// Switches to a different stream for the same video, keeping the position.
    func switchStream(_ stream: Stream, addonTransportUrl: String?) {
        let position = state.time
        reportProgress(force: true)
        request.stream = stream
        request.addonTransportUrl = addonTransportUrl
        request.startAt = position > 0 ? position : nil
        handledEnd = false
        Task { await start() }
    }
}
