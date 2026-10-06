import AppKit
import AVFoundation

/// AVFoundation playback, used when libmpv isn't available. Handles MP4/HLS/MOV streams;
/// MKV and many torrent releases need the mpv engine.
@MainActor
final class AVEngine: PlaybackEngine {
    let name = "AVFoundation"
    let state = PlaybackState()
    let supportsExternalSubtitles = false
    let videoView: NSView

    private let player = AVPlayer()
    private let playerLayer: AVPlayerLayer
    private var timeObserver: Any?
    private var observations: [NSKeyValueObservation] = []
    private var endObserver: NSObjectProtocol?
    private var audioOptions: [AVMediaSelectionOption] = []
    private var subtitleOptions: [AVMediaSelectionOption] = []

    init() {
        playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        let view = AVLayerView(playerLayer: playerLayer)
        videoView = view

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.state.time = time.seconds.isFinite ? time.seconds : 0
                if let item = self.player.currentItem {
                    let duration = item.duration.seconds
                    if duration.isFinite { self.state.duration = duration }
                    if let range = item.loadedTimeRanges.last?.timeRangeValue {
                        self.state.bufferedUntil = (range.start + range.duration).seconds
                    }
                }
            }
        }
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.state.isPaused = player.timeControlStatus == .paused
                self.state.isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            }
        })
        observations.append(player.observe(\.volume, options: [.new]) { [weak self] player, _ in
            DispatchQueue.main.async { self?.state.volume = Double(player.volume * 100) }
        })
    }

    func load(_ url: URL, startAt seconds: Double?) {
        state.reset()
        let item = AVPlayerItem(url: url)
        observations.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    self.state.isLoaded = true
                    self.state.isBuffering = false
                    if let size = item.presentationSize as CGSize?, size != .zero { self.state.videoSize = size }
                    Task { await self.loadTracks(item) }
                case .failed:
                    self.state.error = item.error?.localizedDescription ?? "This stream can't be played by AVFoundation. Install mpv for full format support."
                    self.state.isBuffering = false
                default: break
                }
            }
        })
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.state.didReachEnd = true }
        }
        player.replaceCurrentItem(with: item)
        if let seconds, seconds > 0 {
            item.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), completionHandler: nil)
        }
        player.play()
    }

    private func loadTracks(_ item: AVPlayerItem) async {
        let asset = item.asset
        if let group = try? await asset.loadMediaSelectionGroup(for: .audible) {
            audioOptions = group.options
            state.audioTracks = group.options.enumerated().map { index, option in
                MediaTrack(id: String(index), kind: .audio, title: option.displayName,
                           lang: option.extendedLanguageTag ?? option.locale?.language.languageCode?.identifier, isExternal: false)
            }
            if let selected = item.currentMediaSelection.selectedMediaOption(in: group), let index = group.options.firstIndex(of: selected) {
                state.selectedAudioId = String(index)
            }
        }
        if let group = try? await asset.loadMediaSelectionGroup(for: .legible) {
            subtitleOptions = group.options
            state.subtitleTracks = group.options.enumerated().map { index, option in
                MediaTrack(id: String(index), kind: .subtitle, title: option.displayName,
                           lang: option.extendedLanguageTag ?? option.locale?.language.languageCode?.identifier, isExternal: false)
            }
            if let selected = item.currentMediaSelection.selectedMediaOption(in: group), let index = group.options.firstIndex(of: selected) {
                state.selectedSubtitleId = String(index)
            }
        }
    }

    func setPaused(_ paused: Bool) {
        if paused { player.pause() } else { player.play() }
        state.isPaused = paused
    }

    func seek(to seconds: Double) {
        state.time = seconds
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setVolume(_ volume: Double) {
        player.volume = Float(min(max(volume, 0), 100) / 100)
        state.volume = volume
        if state.isMuted { setMuted(false) }
    }

    func setMuted(_ muted: Bool) {
        player.isMuted = muted
        state.isMuted = muted
    }

    func setSpeed(_ speed: Double) {
        player.rate = Float(speed)
        player.defaultRate = Float(speed)
        state.speed = speed
    }

    func selectAudioTrack(_ id: String) {
        guard let item = player.currentItem, let index = Int(id), index < audioOptions.count else { return }
        Task {
            if let group = try? await item.asset.loadMediaSelectionGroup(for: .audible) {
                item.select(audioOptions[index], in: group)
                state.selectedAudioId = id
            }
        }
    }

    func selectSubtitleTrack(_ id: String?) {
        guard let item = player.currentItem else { return }
        Task {
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else { return }
            if let id, let index = Int(id), index < subtitleOptions.count {
                item.select(subtitleOptions[index], in: group)
            } else {
                item.select(nil, in: group)
            }
            state.selectedSubtitleId = id
        }
    }

    func addExternalSubtitle(url: URL, title: String, lang: String) {}

    func setSubtitleDelay(_ seconds: Double) {}

    func setSubtitleScale(_ scale: Double) {}

    func setSubtitleSpeed(_ speed: Double) {}

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        observations.removeAll()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }
}

private final class AVLayerView: NSView {
    private let playerLayer: AVPlayerLayer

    init(playerLayer: AVPlayerLayer) {
        self.playerLayer = playerLayer
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}
