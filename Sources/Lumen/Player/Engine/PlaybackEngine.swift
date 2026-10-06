import AppKit
import Observation

struct MediaTrack: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable { case video, audio, subtitle }

    /// Engine-specific identifier (mpv track id, or AVFoundation option index).
    var id: String
    var kind: Kind
    var title: String?
    var lang: String?
    var codec: String?
    var isExternal: Bool
    var isDefault: Bool = false
    /// Stream index inside the media container (ffmpeg `0:<index>`), when known.
    var ffIndex: Int?

    var displayName: String {
        let language = lang.map { ISOLanguage.name(for: $0) }
        switch (title, language) {
        case let (title?, language?) where !title.isEmpty && title.lowercased() != language.lowercased():
            return "\(language) – \(title)"
        case let (_, language?): return language
        case let (title?, nil) where !title.isEmpty: return title
        default: return "Track \(id)"
        }
    }
}

/// Observable playback state written by the active engine on the main thread.
@MainActor
@Observable
final class PlaybackState {
    var time: Double = 0
    var duration: Double = 0
    var isPaused = false
    var isBuffering = true
    var bufferedUntil: Double = 0
    var cacheProgress: Double?
    var volume: Double = 100
    var isMuted = false
    var speed: Double = 1
    var subtitleDelay: Double = 0
    var subtitleSpeed: Double = 1
    var audioTracks: [MediaTrack] = []
    var subtitleTracks: [MediaTrack] = []
    var selectedAudioId: String?
    var selectedSubtitleId: String?
    var isLoaded = false
    var didReachEnd = false
    var error: String?
    var videoSize: CGSize?

    func reset() {
        time = 0
        duration = 0
        isPaused = false
        isBuffering = true
        bufferedUntil = 0
        cacheProgress = nil
        audioTracks = []
        subtitleTracks = []
        selectedAudioId = nil
        selectedSubtitleId = nil
        isLoaded = false
        didReachEnd = false
        error = nil
        videoSize = nil
        subtitleDelay = 0
        subtitleSpeed = 1
    }
}

@MainActor
protocol PlaybackEngine: AnyObject {
    var name: String { get }
    var state: PlaybackState { get }
    var videoView: NSView { get }
    var supportsExternalSubtitles: Bool { get }

    func load(_ url: URL, startAt seconds: Double?)
    func setPaused(_ paused: Bool)
    func seek(to seconds: Double)
    func setVolume(_ volume: Double)
    func setMuted(_ muted: Bool)
    func setSpeed(_ speed: Double)
    func selectAudioTrack(_ id: String)
    func selectSubtitleTrack(_ id: String?)
    func addExternalSubtitle(url: URL, title: String, lang: String)
    func setSubtitleDelay(_ seconds: Double)
    func setSubtitleScale(_ scale: Double)
    /// Multiplies subtitle timestamps (frame-rate correction).
    func setSubtitleSpeed(_ speed: Double)
    func stop()
}

enum PlaybackEngineFactory {
    @MainActor
    static func make(preference: AppSettings.PlayerEngine, hardwareDecoding: Bool) -> PlaybackEngine {
        switch preference {
        case .avFoundation:
            return AVEngine()
        case .mpv, .automatic:
            if MPVLibrary.load() {
                return MPVEngine(hardwareDecoding: hardwareDecoding)
            }
            return AVEngine()
        }
    }
}
