import AppKit
import SwiftUI

/// Plays on a Chromecast or DLNA TV through the streaming server's casting API. The server
/// probes and transcodes the stream as the device needs and serves it to the TV over the LAN,
/// so `load` takes the same (possibly `127.0.0.1`) URL as the local engines.
@MainActor
final class CastEngine: PlaybackEngine {
    let name = "cast"
    let state = PlaybackState()
    /// Addon subtitles are sent to the device, but delay and auto-sync aren't supported.
    let supportsExternalSubtitles = false
    let videoView: NSView
    let device: StreamingServer.CastDevice
    /// Called when the device fails, or playback is stopped from the TV itself.
    var onFailure: ((String) -> Void)?

    /// Media states reported by the server (`Player.states` in server.js).
    private enum DeviceState: Int {
        case idle, opening, buffering, playing, paused, stopped, ended, error
    }

    private let server: StreamingServer
    private var queue: Task<Void, Never>?
    private var pendingCommands = 0
    private var pollTask: Task<Void, Never>?
    private var failedPolls = 0
    private var isStopped = false
    private var hasFailed = false
    private var hasPlayed = false
    private var stoppedPolls = 0
    private var subtitleURLs: [String: URL] = [:]
    /// Loads and seeks restart the transcode; the device reports stale positions until this time.
    private var settleTime = Date.distantFuture
    /// Position the last load/seek started from, and the offset to add when the device reports
    /// times relative to it instead of absolute ones.
    private var startTime: Double = 0
    private var timeOffset: Double?

    init(device: StreamingServer.CastDevice, server: StreamingServer) {
        self.device = device
        self.server = server
        videoView = NSHostingView(rootView: CastingPlaceholder(deviceName: device.name))
    }

    func load(_ url: URL, startAt seconds: Double?) {
        state.reset()
        subtitleURLs = [:]
        hasPlayed = false
        restart(at: seconds ?? 0)
        send(["source": .string(url.absoluteString), "time": .number((startTime * 1000).rounded())], restarts: true, isLoad: true)
        startPolling()
    }

    func setPaused(_ paused: Bool) {
        state.isPaused = paused
        send(["paused": .bool(paused)])
    }

    func seek(to seconds: Double) {
        // Both device types ignore seeks unless playing.
        if state.isPaused {
            state.isPaused = false
            send(["paused": .bool(false)])
            send([:])
        }
        restart(at: seconds)
        send(["time": .number((seconds * 1000).rounded())], restarts: true)
    }

    func setVolume(_ volume: Double) {
        state.volume = min(100, max(0, volume))
        state.isMuted = false
        send(["volume": .number(state.volume / 100)])
    }

    func setMuted(_ muted: Bool) {
        state.isMuted = muted
        send(["volume": .number(muted ? 0 : state.volume / 100)])
    }

    func setSpeed(_ speed: Double) {}

    func selectAudioTrack(_ id: String) {
        state.selectedAudioId = id
        restart(at: state.time)
        send(["audioTrack": .string(id)], restarts: true)
    }

    func selectSubtitleTrack(_ id: String?) {
        state.selectedSubtitleId = id
        // DLNA burns subtitles into a new transcode; Chromecast switches the text track in place.
        if !device.isChromecast { restart(at: state.time) }
        sendSubtitles(restarts: !device.isChromecast)
    }

    func addExternalSubtitle(url: URL, title: String, lang: String) {
        let id = "cast-\(subtitleURLs.count + 1)"
        subtitleURLs[id] = url
        state.subtitleTracks.append(MediaTrack(id: id, kind: .subtitle, title: title, lang: lang, codec: nil, isExternal: true))
    }

    func setSubtitleDelay(_ seconds: Double) {}
    func setSubtitleScale(_ scale: Double) {}
    func setSubtitleSpeed(_ speed: Double) {}

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        pollTask?.cancel()
        queue?.cancel()
        let server = server, id = device.id
        Task { _ = try? await server.castCommand(id, ["stop": .bool(true)]) }
    }

    // MARK: Commands

    private func restart(at seconds: Double) {
        state.time = seconds
        state.isBuffering = true
        startTime = seconds
        timeOffset = nil
        settleTime = .distantFuture
    }

    /// Serializes commands so the device sees them in order. `restarts` marks commands that
    /// reload the stream on the device.
    private func send(_ params: [String: JSONValue], restarts: Bool = false, isLoad: Bool = false) {
        let previous = queue
        pendingCommands += 1
        queue = Task { [weak self, server, device] in
            await previous?.value
            defer { self?.pendingCommands -= 1 }
            guard let self, !self.isStopped else { return }
            do {
                let status = try await server.castCommand(device.id, params)
                guard !self.isStopped else { return }
                // The server starts the device a few seconds after acknowledging a load or seek.
                if restarts { self.settleTime = Date().addingTimeInterval(6) }
                self.apply(status)
            } catch {
                if isLoad {
                    self.fail(self.describe(error))
                } else {
                    Log.error("Cast command \(params.keys.sorted()) failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func sendSubtitles(restarts: Bool = false) {
        let url = state.selectedSubtitleId.flatMap { subtitleURLs[$0] }
        send(["subtitlesSrc": .string(url?.absoluteString ?? "")], restarts: restarts)
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !self.isStopped else { return }
                guard self.pendingCommands == 0 else { continue }
                do {
                    let status = try await self.server.castCommand(self.device.id)
                    self.failedPolls = 0
                    if !self.isStopped { self.apply(status) }
                } catch {
                    self.failedPolls += 1
                    if self.failedPolls >= 5 { self.fail("Lost connection to \(self.device.name).") }
                }
            }
        }
    }

    // MARK: Status

    private func apply(_ status: JSONValue) {
        if let length = status["length"]?.doubleValue, length > 0 {
            state.duration = length / 1000
            state.isLoaded = true
        }
        if case .array(let streams)? = status["audio"], !streams.isEmpty {
            state.audioTracks = streams.compactMap { stream in
                guard let id = stream["id"]?.stringValue else { return nil }
                let lang = stream["lang"]?.stringValue
                return MediaTrack(id: id, kind: .audio, title: nil, lang: lang == "und" ? nil : lang,
                                  codec: stream["codec"]?.stringValue, isExternal: false)
            }
            if state.selectedAudioId == nil {
                state.selectedAudioId = status["audioTrack"]?.stringValue ?? state.audioTracks.first?.id
            }
        }

        guard Date() >= settleTime else { return }
        let deviceState = status["state"]?.doubleValue.flatMap { DeviceState(rawValue: Int($0)) }
        switch deviceState {
        case .playing, .paused:
            stoppedPolls = 0
            hasPlayed = true
            state.isBuffering = false
            state.isPaused = deviceState == .paused
            guard let reported = status["time"]?.doubleValue.map({ $0 / 1000 }) else { return }
            if timeOffset == nil {
                // First position since a reload. Some receivers count from where the transcode
                // started rather than from 0, and Chromecast drops the active text track.
                timeOffset = startTime > 30 && reported < 15 ? startTime : 0
                if device.isChromecast, state.selectedSubtitleId != nil { sendSubtitles() }
            }
            state.time = reported + (timeOffset ?? 0)
        case .opening, .buffering:
            stoppedPolls = 0
            state.isBuffering = true
        case .ended, .stopped, .idle:
            guard hasPlayed else { return }
            if state.duration > 0, state.duration - state.time < 60 {
                state.didReachEnd = true
                return
            }
            // Devices briefly report stopped/ended between loads; only give up if it persists.
            stoppedPolls += 1
            if stoppedPolls >= 3 { fail("Playback was stopped on \(device.name).") }
        case .error:
            fail(deviceErrorMessage())
        case nil:
            break
        }
    }

    private func describe(_ error: Error) -> String {
        let message = error.localizedDescription
        if message.localizedCaseInsensitiveContains("timeout") || (error as? URLError)?.code == .timedOut {
            return "\(device.name) didn't respond in time. Check that it's on and connected to the same network."
        }
        return "Couldn't play on \(device.name): \(message)"
    }

    /// The server only reports an error state; the device's reason is in its log.
    private func deviceErrorMessage() -> String {
        let marker = "Handle Cast Error "
        let reason = server.log.suffix(50).last { $0.hasPrefix(marker) }.map { String($0.dropFirst(marker.count)) }
        if let reason, reason.contains("(704)") {
            // UPnP "Local restrictions": Samsung TVs answer this until the sender is allowed.
            return "\(device.name) refused the stream. On Samsung TVs, accept the prompt on the TV or allow this Mac "
                + "under Settings › General › External Device Manager › Device Connection Manager."
        }
        return "\(device.name) couldn't play this stream" + (reason.map { " (\($0))." } ?? ".")
    }

    private func fail(_ message: String) {
        guard !isStopped, !hasFailed else { return }
        hasFailed = true
        pollTask?.cancel()
        onFailure?(message)
    }
}

/// Shown in place of the video while casting.
private struct CastingPlaceholder: View {
    var deviceName: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "tv")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.white.opacity(0.5))
            Text("Playing on \(deviceName)")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}
