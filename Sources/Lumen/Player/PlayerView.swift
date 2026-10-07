import AppKit
import SwiftUI

struct PlayerView: View {
    @Environment(AppState.self) private var app
    var session: PlayerSession

    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var keyMonitor: Any?
    @State private var activity: NSObjectProtocol?
    @State private var nowPlaying: NowPlayingController?
    @State private var showStreamPicker = false
    @State private var isHoveringControls = false
    @State private var panel: PlayerPanel?

    private var state: PlaybackState { session.state }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoSurface(view: session.engine.videoView)
                .ignoresSafeArea()
                .onTapGesture(count: 2) { toggleFullScreen() }
                .onTapGesture { session.togglePause(); showControls() }

            if let error = session.resolveError ?? state.error {
                PlayerErrorView(message: error, engineName: session.engine.name) {
                    app.closePlayer()
                }
            } else if state.isBuffering || !state.isLoaded {
                BufferingView(session: session)
                    .allowsHitTesting(false)
            }

            if panel != nil {
                // Clicking the video closes an open panel instead of pausing.
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { panel = nil }
            }

            if controlsVisible || state.isPaused || panel != nil {
                PlayerControls(session: session, isHovering: $isHoveringControls, panel: $panel,
                               onBack: { app.closePlayer() },
                               onFullScreen: toggleFullScreen,
                               onNext: playNext,
                               onStreams: { showStreamPicker = true })
                    .transition(.opacity)
            }

            if let panel {
                PlayerPanelContainer {
                    switch panel {
                    case .subtitles: SubtitlesMenu(session: session)
                    case .audio: AudioMenu(session: session)
                    case .cast: CastMenu(session: session)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 24)
                .padding(.bottom, 84)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottomTrailing)))
            }

            SubtitleSyncToast(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 90)
                .allowsHitTesting(false)

            if let message = session.castMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.black.opacity(0.75), in: Capsule())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 90)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if session.showNextEpisodePrompt, let next = session.nextVideo {
                NextEpisodeCard(video: next, hasStream: session.nextStreamCandidate != nil,
                                onPlay: playNext, onDismiss: { session.dismissNextEpisodePrompt() })
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 32)
                    .padding(.bottom, 120)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
        .animation(.easeOut(duration: 0.15), value: panel)
        .animation(.easeInOut(duration: 0.25), value: session.showNextEpisodePrompt)
        .animation(.easeInOut(duration: 0.2), value: session.castMessage)
        .onContinuousHover { phase in
            if case .active = phase { showControls() }
        }
        .background(WindowChrome(controlsVisible: controlsVisible || state.isPaused))
        .onAppear(perform: onAppear)
        .onDisappear(perform: onDisappear)
        .onChange(of: state.isPaused) { updateSleepPrevention() }
        .onReceive(NotificationCenter.default.publisher(for: .debugOpenPlayerPanel)) { note in
            panel = (note.object as? String) == "audio" ? .audio : .subtitles
        }
        .sheet(isPresented: $showStreamPicker) {
            StreamPickerSheet(session: session)
        }
    }

    // MARK: Lifecycle

    private func onAppear() {
        showControls()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKey(event) ? nil : event
        }
        nowPlaying = NowPlayingController(session: session)
        updateSleepPrevention()
    }

    private func onDisappear() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        hideTask?.cancel()
        nowPlaying?.teardown()
        nowPlaying = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        NSCursor.unhide()
    }

    private func updateSleepPrevention() {
        if !state.isPaused, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated],
                                                             reason: "Video playback")
        } else if state.isPaused, let current = activity {
            ProcessInfo.processInfo.endActivity(current)
            activity = nil
        }
    }

    // MARK: Controls visibility

    private func showControls() {
        if !controlsVisible { controlsVisible = true }
        NSCursor.unhide()
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, !state.isPaused, !isHoveringControls, !showStreamPicker, panel == nil else { return }
            controlsVisible = false
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    private func toggleFullScreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    private func playNext() {
        if !session.playNext() {
            // No automatic stream match: go back to the episode's stream list.
            // Closing lands on the title's page, where the next episode can be picked.
            app.closePlayer()
        }
    }

    // MARK: Keyboard

    private func handleKey(_ event: NSEvent) -> Bool {
        // Let text fields and sheets handle their own input.
        if showStreamPicker || NSApp.keyWindow?.firstResponder is NSTextView { return false }
        let step = Double(app.profile.settings.seekStepSeconds)
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 49: session.togglePause() // space
        case 123: session.seek(by: shift ? -step * 3 : -step) // left
        case 124: session.seek(by: shift ? step * 3 : step) // right
        case 126: session.setVolume(state.volume + 5) // up
        case 125: session.setVolume(state.volume - 5) // down
        case 53: // escape
            if panel != nil {
                panel = nil
            } else if let window = NSApp.keyWindow, window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            } else {
                app.closePlayer()
            }
        default:
            guard let characters = event.charactersIgnoringModifiers?.lowercased(),
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
            switch characters {
            case "f": toggleFullScreen()
            case "m": session.toggleMute()
            case "n": playNext()
            case "[": session.setSpeed(max(0.25, state.speed - 0.25))
            case "]": session.setSpeed(min(4, state.speed + 0.25))
            case "g": session.adjustSubtitleDelay(by: -0.1)
            case "h": session.adjustSubtitleDelay(by: 0.1)
            default: return false
            }
        }
        showControls()
        return true
    }
}

/// Hosts the engine's video NSView.
private struct VideoSurface: NSViewRepresentable {
    var view: NSView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        attach(view, to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if view.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            attach(view, to: container)
        }
    }

    private func attach(_ view: NSView, to container: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

/// Makes the window chrome immersive while the player is visible.
private struct WindowChrome: NSViewRepresentable {
    var controlsVisible: Bool

    final class Coordinator {
        weak var window: NSWindow?
        var originalStyle: NSWindow.StyleMask?
        var originalTransparent = false
        var originalToolbarVisible = true
        var fullScreenObservers: [NSObjectProtocol] = []
    }

    /// SwiftUI's toolbar hiding leaves the toolbar's background strip in full screen (where
    /// AppKit hosts the toolbar in its own overlay window), so hide the NSToolbar itself.
    private static func hideToolbar(_ window: NSWindow) {
        if window.toolbar?.isVisible == true { window.toolbar?.isVisible = false }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            context.coordinator.window = window
            context.coordinator.originalStyle = window.styleMask
            context.coordinator.originalTransparent = window.titlebarAppearsTransparent
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = .black
            context.coordinator.originalToolbarVisible = window.toolbar?.isVisible ?? true
            Self.hideToolbar(window)
            // Entering/leaving full screen rebuilds the titlebar; hide the toolbar again.
            context.coordinator.fullScreenObservers = [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                                                       NSWindow.willEnterFullScreenNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
                    MainActor.assumeIsolated { Self.hideToolbar(window) }
                }
            }
            setButtons(window, visible: controlsVisible)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = context.coordinator.window {
            Self.hideToolbar(window)
            setButtons(window, visible: controlsVisible)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.fullScreenObservers.forEach(NotificationCenter.default.removeObserver)
        coordinator.fullScreenObservers = []
        guard let window = coordinator.window else { return }
        window.toolbar?.isVisible = coordinator.originalToolbarVisible
        if let style = coordinator.originalStyle {
            if window.styleMask.contains(.fullScreen) {
                // Changing the style mid full-screen breaks the transition; restore once it has exited.
                var token: NSObjectProtocol?
                token = NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { _ in
                    window.styleMask = style
                    if let token { NotificationCenter.default.removeObserver(token) }
                }
            } else {
                window.styleMask = style
            }
        }
        window.titlebarAppearsTransparent = coordinator.originalTransparent
        window.titleVisibility = .visible
        window.backgroundColor = .windowBackgroundColor
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.alphaValue = 1
        }
    }

    private func setButtons(_ window: NSWindow, visible: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(type)?.animator().alphaValue = visible ? 1 : 0
            }
        }
    }
}

// MARK: - Controls

enum PlayerPanel: Equatable {
    case subtitles
    case audio
    case cast
}

/// In-player menu panel. Drawn inside the player (not an NSPopover) so it keeps a stable
/// size and position, including in full screen.
private struct PlayerPanelContainer<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(width: 320)
            .background(Color(red: 0.07, green: 0.06, blue: 0.11).opacity(0.94))
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.08)))
            .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
    }
}

private struct PlayerControls: View {
    var session: PlayerSession
    @Binding var isHovering: Bool
    @Binding var panel: PlayerPanel?
    var onBack: () -> Void
    var onFullScreen: () -> Void
    var onNext: () -> Void
    var onStreams: () -> Void
    @State private var isTitleHovered = false

    private var state: PlaybackState { session.state }

    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack(spacing: 14) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(IconButtonStyle(size: 38))
                .help("Back (Esc)")
                Button(action: onBack) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(session.title)
                                .font(.system(size: 17, weight: .bold))
                            if session.request.meta != nil {
                                Image(systemName: "info.circle")
                                    .font(.system(size: 13, weight: .semibold))
                                    .opacity(isTitleHovered ? 1 : 0.6)
                            }
                        }
                        if let subtitle = session.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: 12.5))
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(session.request.meta == nil)
                .onHover { isTitleHovered = $0 }
                .help("Show details")
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 34)
            .padding(.bottom, 40)
            .background(LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom))
            .onHover { isHovering = $0 }

            Spacer()

            // Bottom bar
            VStack(spacing: 10) {
                Scrubber(session: session)
                HStack(spacing: 14) {
                    Button { session.togglePause() } label: {
                        Image(systemName: state.isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 22))
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .help(state.isPaused ? "Play (Space)" : "Pause (Space)")

                    Button { session.seek(by: -10) } label: { Image(systemName: "gobackward.10") }
                        .buttonStyle(.plain)
                    Button { session.seek(by: 10) } label: { Image(systemName: "goforward.10") }
                        .buttonStyle(.plain)
                    if session.nextVideo != nil {
                        Button(action: onNext) { Image(systemName: "forward.end.fill") }
                            .buttonStyle(.plain)
                            .help("Next episode (N)")
                    }

                    Text("\(Format.duration(state.time)) / \(Format.duration(state.duration))")
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))

                    Spacer()

                    VolumeControl(session: session)

                    Button { panel = panel == .subtitles ? nil : .subtitles } label: {
                        Image(systemName: panel == .subtitles ? "captions.bubble.fill" : "captions.bubble")
                    }
                    .buttonStyle(.plain)
                    .help("Subtitles")

                    Button { panel = panel == .audio ? nil : .audio } label: {
                        Image(systemName: "waveform")
                            .foregroundStyle(panel == .audio ? Theme.accent : .white)
                    }
                    .buttonStyle(.plain)
                    .help("Audio & speed")

                    Button { panel = panel == .cast ? nil : .cast } label: {
                        Image(systemName: session.castDevice != nil ? "tv.fill" : "tv")
                            .foregroundStyle(panel == .cast || session.castDevice != nil ? Theme.accent : .white)
                    }
                    .buttonStyle(.plain)
                    .help("Play on TV")

                    if session.request.meta != nil {
                        Button(action: onStreams) { Image(systemName: "list.bullet.rectangle") }
                            .buttonStyle(.plain)
                            .help("Switch stream")
                    }

                    Button(action: onFullScreen) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(.plain)
                    .help("Full screen (F)")
                }
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
            }
            .padding(.horizontal, 24)
            .padding(.top, 40)
            .padding(.bottom, 20)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom))
            .onHover { isHovering = $0 }
        }
        .ignoresSafeArea()
    }
}

private struct Scrubber: View {
    var session: PlayerSession
    @State private var dragValue: Double?
    @State private var hoverX: CGFloat?

    private var state: PlaybackState { session.state }

    var body: some View {
        GeometryReader { geo in
            let duration = max(state.duration, 0.001)
            let current = (dragValue ?? state.time) / duration
            let buffered = min(1, state.bufferedUntil / duration)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2)).frame(height: 5)
                Capsule().fill(.white.opacity(0.35)).frame(width: geo.size.width * max(buffered, current), height: 5)
                Capsule().fill(Theme.accent).frame(width: geo.size.width * current, height: 5)
                Circle()
                    .fill(.white)
                    .frame(width: 14, height: 14)
                    .offset(x: geo.size.width * current - 7)
                    .shadow(radius: 2)
                if let hoverX, state.duration > 0 {
                    Text(Format.duration(Double(hoverX / geo.size.width) * duration))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
                        .offset(x: min(max(hoverX - 24, 0), geo.size.width - 48), y: -22)
                }
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): hoverX = min(max(location.x, 0), geo.size.width)
                case .ended: hoverX = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = min(max(value.location.x / geo.size.width, 0), 1)
                        dragValue = fraction * duration
                    }
                    .onEnded { value in
                        let fraction = min(max(value.location.x / geo.size.width, 0), 1)
                        session.seek(to: fraction * duration)
                        dragValue = nil
                    }
            )
        }
        .frame(height: 20)
    }
}

private struct VolumeControl: View {
    var session: PlayerSession
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button { session.toggleMute() } label: {
                Image(systemName: icon).frame(width: 24)
            }
            .buttonStyle(.plain)
            .help("Mute (M)")
            if isHovered {
                Slider(value: Binding(get: { session.state.isMuted ? 0 : session.state.volume },
                                      set: { session.setVolume($0) }), in: 0...100)
                    .frame(width: 90)
                    .controlSize(.small)
                    .tint(.white)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .onHover { hovering in withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering } }
    }

    private var icon: String {
        let volume = session.state.volume
        if session.state.isMuted || volume == 0 { return "speaker.slash.fill" }
        if volume < 34 { return "speaker.wave.1.fill" }
        if volume < 67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

private struct SubtitlesMenu: View {
    var session: PlayerSession
    @State private var language: String?

    private var addonLanguages: [String] {
        var seen: [String] = []
        for subtitle in session.addonSubtitles {
            let code = ISOLanguage.normalize(subtitle.subtitle.lang)
            if !seen.contains(code) { seen.append(code) }
        }
        return seen.sorted { ISOLanguage.name(for: $0) < ISOLanguage.name(for: $1) }
    }

    /// Language of the addon subtitle currently in use, if any.
    private var selectedAddonLanguage: String? {
        session.addonSubtitles.first { $0.id == session.selectedAddonSubtitleId }
            .map { ISOLanguage.normalize($0.subtitle.lang) }
    }

    // One column; languages drill into a sub-list with a back button.
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let language {
                    languageList(language)
                        .transition(.move(edge: .trailing))
                } else {
                    mainList
                        .transition(.move(edge: .leading))
                }
            }
            .animation(.easeInOut(duration: 0.18), value: language)
            .frame(height: 340)
            .clipped()
            if session.engine.supportsExternalSubtitles {
                Divider().overlay(Color.white.opacity(0.08))
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Delay").font(.caption).foregroundStyle(.secondary)
                        Button { session.adjustSubtitleDelay(by: -0.25) } label: { Image(systemName: "minus") }
                        Text(String(format: "%+.2fs", session.state.subtitleDelay))
                            .font(.caption.monospacedDigit())
                            .frame(width: 56)
                        Button { session.adjustSubtitleDelay(by: 0.25) } label: { Image(systemName: "plus") }
                        Spacer()
                        Button {
                            session.autoSyncSubtitles()
                        } label: {
                            if session.subtitleSync == .running {
                                HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("Syncing…") }
                            } else {
                                Label("Auto Sync", systemImage: "wand.and.stars")
                            }
                        }
                        .font(.caption.weight(.semibold))
                        .disabled(!session.canAutoSyncSubtitles || session.subtitleSync == .running)
                        .help("Match the subtitles to the dialogue around the current position")
                    }
                    if let status = SubtitleSyncStatus.text(for: session.subtitleSync) {
                        Text(status)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }

    private var mainList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                sectionHeader("Subtitles")
                MenuRow(title: "Off", isSelected: session.state.selectedSubtitleId == nil) { session.disableSubtitles() }
                if !session.embeddedSubtitleTracks.isEmpty {
                    sectionHeader("Embedded")
                    ForEach(session.embeddedSubtitleTracks) { track in
                        MenuRow(title: track.displayName,
                                isSelected: session.state.selectedSubtitleId == track.id && session.selectedAddonSubtitleId == nil) {
                            session.selectEmbeddedSubtitle(track)
                        }
                    }
                }
                if !addonLanguages.isEmpty {
                    sectionHeader("From addons")
                    ForEach(addonLanguages, id: \.self) { code in
                        MenuRow(title: ISOLanguage.name(for: code),
                                detail: "\(session.addonSubtitles.filter { ISOLanguage.normalize($0.subtitle.lang) == code }.count) available",
                                isSelected: selectedAddonLanguage == code, showsChevron: true) {
                            language = code
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    private func languageList(_ language: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                self.language = nil
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                    Text(ISOLanguage.name(for: language)).font(.system(size: 13, weight: .semibold))
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(session.addonSubtitles.filter { ISOLanguage.normalize($0.subtitle.lang) == language }) { subtitle in
                        MenuRow(title: subtitle.subtitle.label ?? subtitle.addonName,
                                detail: subtitle.subtitle.label == nil ? nil : subtitle.addonName,
                                isSelected: session.selectedAddonSubtitleId == subtitle.id) {
                            session.selectAddonSubtitle(subtitle)
                        }
                    }
                }
                .padding(8)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }
}

enum SubtitleSyncStatus {
    static func text(for state: PlayerSession.SubtitleSyncState) -> String? {
        switch state {
        case .idle: return nil
        case .running: return "Listening to the dialogue around this point…"
        case let .synced(offset, scale):
            var text = String(format: "Synced: shifted %+.2f s", offset)
            if scale != 1 { text += String(format: ", frame rate corrected (×%.4f)", scale) }
            return text
        case .failed(let message): return message
        }
    }
}

/// Transient pill shown over the video while/after auto-syncing subtitles.
private struct SubtitleSyncToast: View {
    var session: PlayerSession
    @State private var visible = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        Group {
            if visible, let text = SubtitleSyncStatus.text(for: session.subtitleSync) {
                HStack(spacing: 8) {
                    switch session.subtitleSync {
                    case .running: ProgressView().controlSize(.small).tint(.white)
                    case .synced: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
                    case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.yellow)
                    case .idle: EmptyView()
                    }
                    Text(text).font(.system(size: 13, weight: .medium))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.black.opacity(0.75), in: Capsule())
                .foregroundStyle(.white)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: visible)
        .onChange(of: session.subtitleSync) { _, state in
            hideTask?.cancel()
            visible = state != .idle
            guard state != .running, state != .idle else { return }
            hideTask = Task {
                try? await Task.sleep(for: .seconds(5))
                if !Task.isCancelled { visible = false }
            }
        }
    }
}

private struct AudioMenu: View {
    var session: PlayerSession

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("AUDIO").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary).padding(8)
            if session.state.audioTracks.isEmpty {
                Text("No audio tracks").foregroundStyle(.secondary).padding(8)
            }
            ForEach(session.state.audioTracks) { track in
                MenuRow(title: track.displayName, detail: track.codec?.uppercased(),
                        isSelected: session.state.selectedAudioId == track.id) {
                    session.selectAudio(track)
                }
            }
            if session.castDevice == nil {
                speedControls
            }
        }
        .padding(8)
    }

    private var speedControls: some View {
        VStack(alignment: .leading, spacing: 2) {
            Divider().padding(.vertical, 6)
            Text("SPEED").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary).padding(.horizontal, 8)
            HStack(spacing: 4) {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                    Button {
                        session.setSpeed(speed)
                    } label: {
                        Text(speed == 1 ? "1×" : String(format: "%g×", speed))
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(abs(session.state.speed - speed) < 0.01 ? Theme.accent : Color.white.opacity(0.08),
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
        }
    }
}

/// Lists TVs found by the streaming server, plus this Mac.
private struct CastMenu: View {
    @Environment(AppState.self) private var app
    var session: PlayerSession
    @State private var devices: [StreamingServer.CastDevice] = []
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("PLAY ON").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                Spacer()
                if isLoading {
                    ProgressView().controlSize(.mini)
                } else {
                    Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .help("Refresh")
                }
            }
            .padding(8)
            MenuRow(title: "This Mac", isSelected: session.castDevice == nil) { session.stopCasting() }
            ForEach(devices) { device in
                MenuRow(title: device.name, detail: device.isChromecast ? "Chromecast" : "DLNA",
                        isSelected: session.castDevice?.id == device.id) {
                    session.startCasting(to: device)
                }
            }
            if let note = error ?? (!isLoading && devices.isEmpty ? Self.noDevicesNote : nil) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
            }
        }
        .padding(8)
        .task { await load() }
    }

    private static let noDevicesNote = "No TVs found. Chromecast and DLNA TVs on the same network show up here. "
        + "The streaming server looks for them when it starts, so a TV turned on later needs a server restart (Settings)."

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        guard app.server.status.isRunning else {
            error = "Casting needs the streaming server, which isn't running."
            return
        }
        do {
            devices = try await app.server.castDevices()
            error = nil
        } catch {
            self.error = "Couldn't list TVs: \(error.localizedDescription)"
        }
    }
}

private struct MenuRow: View {
    var title: String
    var detail: String?
    var isSelected: Bool
    var showsChevron = false
    var action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .opacity(isSelected ? 1 : 0)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1)
                    if let detail {
                        Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if showsChevron { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(isHovered ? Color.white.opacity(0.1) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct BufferingView: View {
    var session: PlayerSession

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            if let stats = session.torrentStats {
                VStack(spacing: 4) {
                    if let speed = stats.downloadSpeed {
                        Text(Format.bytesPerSecond(speed))
                            .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    }
                    Text("\(stats.peers ?? 0) peers")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                }
            } else if session.resolvedURL == nil {
                Text("Preparing stream…")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
            } else if let progress = session.state.cacheProgress, progress > 0 {
                Text("Buffering \(Int(progress * 100))%")
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .foregroundStyle(.white)
        .padding(24)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct PlayerErrorView: View {
    var message: String
    var engineName: String
    var onBack: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(Theme.yellow)
            Text("Playback error").font(.title2.bold())
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.75))
                .frame(maxWidth: 460)
            if engineName != "mpv" && !MPVLibrary.isAvailable {
                Text("Tip: install mpv (`brew install mpv`) or Stremio to play MKV and other formats.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.6))
            }
            Button("Go Back", action: onBack)
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(32)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 18))
        .foregroundStyle(.white)
    }
}

private struct NextEpisodeCard: View {
    var video: Video
    var hasStream: Bool
    var onPlay: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            CachedImage(url: video.thumbnail)
                .frame(width: 140, height: 79)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text("NEXT EPISODE")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                Text(video.title.isEmpty ? video.label : video.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                if let season = video.season, let episode = video.episode {
                    Text("S\(season) E\(episode)").font(.caption).foregroundStyle(.white.opacity(0.6))
                }
                HStack(spacing: 8) {
                    Button(hasStream ? "Play" : "Choose stream", action: onPlay)
                        .buttonStyle(PrimaryButtonStyle())
                    Button("Dismiss", action: onDismiss)
                        .buttonStyle(SecondaryButtonStyle())
                }
                .padding(.top, 4)
            }
        }
        .padding(14)
        .frame(width: 420)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .foregroundStyle(.white)
    }
}

/// Lets the user switch to another stream of the same video without leaving the player.
private struct StreamPickerSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    var session: PlayerSession
    @State private var groups: [AddonStreams] = []
    /// Selected provider (addon transport URL); nil shows every provider.
    @State private var provider: String?
    @State private var userPickedProvider = false
    @State private var preferredProvider: String?

    private var providersWithStreams: [AddonStreams] { groups.filter { !$0.streams.isEmpty } }

    private var visibleGroups: [AddonStreams] {
        guard let provider else { return groups }
        return groups.filter { $0.id == provider }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("Streams").font(.title3.bold())
                Picker("Provider", selection: Binding(
                    get: { provider },
                    set: { provider = $0; userPickedProvider = true }
                )) {
                    Text("All providers (\(providersWithStreams.reduce(0) { $0 + $1.streams.count }))").tag(String?.none)
                    if !providersWithStreams.isEmpty { Divider() }
                    ForEach(providersWithStreams) { group in
                        Text("\(group.addon.manifest.name) (\(group.streams.count))").tag(String?.some(group.id))
                    }
                }
                .labelsHidden()
                .fixedSize()
                if groups.contains(where: \.isLoading) {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(visibleGroups) { group in
                        if group.isLoading && provider == nil {
                            HStack { ProgressView().controlSize(.small); Text(group.addon.manifest.name).foregroundStyle(.secondary) }
                        }
                        ForEach(group.streams) { stream in
                            Button {
                                session.switchStream(stream, addonTransportUrl: group.addon.transportUrl)
                                dismiss()
                            } label: {
                                HStack(alignment: .top) {
                                    Text(stream.displayName.isEmpty ? group.addon.manifest.name : stream.displayName)
                                        .bold()
                                        .frame(width: 110, alignment: .leading)
                                    Text(stream.displayDescription)
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    if stream.id == session.request.stream.id {
                                        Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                    }
                                }
                                .font(.system(size: 12))
                                .padding(10)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 620, height: 520)
        .task { await load() }
    }

    private func load() async {
        guard let meta = session.request.meta else { return }
        let videoId = session.request.videoId ?? meta.id
        let available = app.profile.addons(supporting: "stream", type: meta.type, id: videoId)
        // Same preference as the title page: Torrentio RD first and pre-selected.
        preferredProvider = StreamAddonPreference.preferred(among: available, setting: app.profile.settings.preferredStreamAddon)?.transportUrl
        let addons = available.filter { $0.transportUrl == preferredProvider } + available.filter { $0.transportUrl != preferredProvider }
        groups = addons.map { AddonStreams(addon: $0) }
        let type = meta.type
        await forEachConcurrently(addons) { addon in
            (try? await AddonClient.shared.streams(addon: addon, type: type, id: videoId)) ?? []
        } onResult: { addon, streams in
            if let index = groups.firstIndex(where: { $0.id == addon.transportUrl }) {
                groups[index].streams = streams
                groups[index].isLoading = false
            }
            if !userPickedProvider, addon.transportUrl == preferredProvider, !streams.isEmpty {
                provider = preferredProvider
            }
        }
    }
}
