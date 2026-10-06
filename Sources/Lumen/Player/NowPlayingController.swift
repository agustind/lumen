import AppKit
import MediaPlayer

/// Publishes playback to Control Center / the Now Playing widget and handles media keys.
@MainActor
final class NowPlayingController {
    private weak var session: PlayerSession?
    private var targets: [(MPRemoteCommand, Any)] = []
    private var updateTask: Task<Void, Never>?
    private var artwork: MPMediaItemArtwork?

    init(session: PlayerSession) {
        self.session = session
        let center = MPRemoteCommandCenter.shared()
        add(center.togglePlayPauseCommand) { $0.togglePause() }
        add(center.playCommand) { $0.engine.setPaused(false) }
        add(center.pauseCommand) { $0.engine.setPaused(true) }
        add(center.skipForwardCommand) { $0.seek(by: 10) }
        add(center.skipBackwardCommand) { $0.seek(by: -10) }
        add(center.nextTrackCommand) { $0.playNext() }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        let seekTarget = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.session?.seek(to: event.positionTime) }
            return .success
        }
        targets.append((center.changePlaybackPositionCommand, seekTarget))

        if let poster = session.request.meta?.poster {
            Task {
                if let image = await ImageLoader.shared.image(for: poster) {
                    artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                }
            }
        }
        updateTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.update()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor (PlayerSession) -> Void) {
        command.isEnabled = true
        let target = command.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let session = self?.session else { return }
                action(session)
            }
            return .success
        }
        targets.append((command, target))
    }

    private func update() {
        guard let session else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: session.subtitle.map { "\(session.title) – \($0)" } ?? session.title,
            MPMediaItemPropertyPlaybackDuration: session.state.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: session.state.time,
            MPNowPlayingInfoPropertyPlaybackRate: session.state.isPaused ? 0.0 : session.state.speed,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = session.state.isPaused ? .paused : .playing
    }

    func teardown() {
        updateTask?.cancel()
        for (command, target) in targets { command.removeTarget(target) }
        targets.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }
}
