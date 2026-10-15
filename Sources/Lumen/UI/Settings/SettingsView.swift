import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @State private var serverSettings: StreamingServer.ServerSettings?
    @State private var showServerLog = false

    var body: some View {
        @Bindable var profile = app.profile
        Form {
            Section("Account") {
                if let auth = app.profile.auth {
                    LabeledContent("Logged in as", value: auth.user.email)
                    HStack {
                        Button("Sync Now") {
                            Task {
                                await app.profile.pullAddons()
                                await app.library.sync()
                            }
                        }
                        .disabled(app.library.isSyncing || app.profile.isSyncing)
                        if app.library.isSyncing || app.profile.isSyncing { ProgressView().controlSize(.small) }
                        Spacer()
                        Button("Log Out", role: .destructive) { Task { await app.logout() } }
                    }
                } else {
                    HStack {
                        Text("Log in to sync your library and addons with your other devices.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Log In or Sign Up") { app.showLogin = true }
                    }
                }
            }

            Section("Player") {
                Picker("Playback engine", selection: $profile.settings.playerEngine) {
                    ForEach(AppSettings.PlayerEngine.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("mpv") {
                    if MPVLibrary.isAvailable {
                        Text("Available").foregroundStyle(Theme.green)
                    } else {
                        Text("Not found – install with `brew install mpv` or install Stremio").foregroundStyle(.secondary)
                    }
                }
                Toggle("Hardware decoding", isOn: $profile.settings.hardwareDecoding)
                Toggle("Auto-play next episode", isOn: $profile.settings.bingeWatching)
                Picker("Seek step", selection: $profile.settings.seekStepSeconds) {
                    ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) seconds").tag($0) }
                }
            }

            Section("Streams") {
                Picker("Pre-selected stream addon", selection: $profile.settings.preferredStreamAddon) {
                    Text("Torrentio RD").tag(AppSettings.automaticStreamAddon)
                    Text("None (show all)").tag("")
                    ForEach(app.profile.activeAddons.filter {
                        $0.manifest.resourceNames.contains("stream")
                            && !(StreamAddonPreference.isTorrentio($0) && StreamAddonPreference.isRealDebrid($0))
                    }) { addon in
                        Text(addon.manifest.name).tag(addon.transportUrl)
                    }
                }
            }

            Section("Subtitles & Audio") {
                Picker("Default subtitles", selection: $profile.settings.subtitlesLanguage) {
                    Text("None").tag("")
                    ForEach(ISOLanguage.allChoices, id: \.code) { Text($0.name).tag($0.code) }
                }
                Picker("Subtitle size", selection: $profile.settings.subtitlesSize) {
                    ForEach([75, 100, 125, 150, 200], id: \.self) { Text("\($0)%").tag($0) }
                }
                Picker("Preferred audio", selection: $profile.settings.audioLanguage) {
                    Text("Default").tag("")
                    ForEach(ISOLanguage.allChoices, id: \.code) { Text($0.name).tag($0.code) }
                }
            }

            Section("Streaming Server") {
                LabeledContent("Status") { serverStatus }
                TextField("Server URL", text: $profile.settings.streamingServerURL)
                    .onSubmit {
                        if let url = URL(string: app.profile.settings.streamingServerURL) {
                            app.server.baseURL = url
                            Task { await app.server.probe() }
                        }
                    }
                Toggle("Start the streaming server automatically", isOn: $profile.settings.startStreamingServer)
                if let serverSettings {
                    ForEach(serverSettings.options.filter { $0.type == "select" }) { option in
                        Picker(Self.serverOptionTitle(option), selection: Binding(
                            get: { serverSettings.values[option.id] ?? .null },
                            set: { newValue in
                                Task {
                                    try? await app.server.updateSettings([option.id: newValue])
                                    self.serverSettings = try? await app.server.fetchSettings()
                                }
                            }
                        )) {
                            ForEach(Array(option.selections.enumerated()), id: \.offset) { _, selection in
                                Text(selection.name).tag(selection.value)
                            }
                        }
                    }
                }
                HStack {
                    Button("Restart Server") {
                        Task {
                            await app.server.restart()
                            serverSettings = try? await app.server.fetchSettings()
                        }
                    }
                    Button("Show Log") { showServerLog = true }
                }
            }

            Section("Content") {
                Toggle("Show adult addons", isOn: $profile.settings.showAdultAddons)
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
                LabeledContent("mpv library", value: MPVLibrary.loadedPath ?? "–")
                LabeledContent("Recommendations", value: TMDBClient.isConfigured ? "TMDB" : "Popular titles in the same genre")
                if TMDBClient.isConfigured {
                    // Attribution required by TMDB's API terms.
                    Text("This product uses the TMDB API but is not endorsed or certified by TMDB.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Show Data Folder") { NSWorkspace.shared.open(Storage.directory) }
                    Button("Clear Caches") {
                        Task { await AddonClient.shared.clearCache() }
                        URLCache.shared.removeAllCachedResponses()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Settings")
        .task(id: app.server.status) {
            if app.server.status.isRunning { serverSettings = try? await app.server.fetchSettings() }
        }
        .sheet(isPresented: $showServerLog) {
            ServerLogSheet()
        }
    }

    /// The server reports translation keys (stremio-translations) as labels.
    private static func serverOptionTitle(_ option: StreamingServer.ServerSettings.Option) -> String {
        let known = [
            "CACHING": "Cache size",
            "ENABLE_REMOTE_HTTPS_CONN": "Remote HTTPS connections",
            "TRANSCODE_PROFILE": "Transcoding profile",
            "BT_MAX_CONNECTIONS": "Torrent connections",
            "PROXY_STREAMS_ENABLED": "Proxy streams",
        ]
        if let title = known[option.label] { return title }
        guard option.label == option.label.uppercased() else { return option.label }
        return option.label.replacingOccurrences(of: "_", with: " ").capitalized
    }

    @ViewBuilder
    private var serverStatus: some View {
        switch app.server.status {
        case .unknown:
            Text("Checking…").foregroundStyle(.secondary)
        case .starting:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Starting…") }
        case .running(let version, let external):
            Text("Running\(version.map { " · v\($0)" } ?? "")\(external ? " (external)" : "")")
                .foregroundStyle(Theme.green)
        case .stopped:
            Text("Not running").foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).foregroundStyle(Theme.danger).multilineTextAlignment(.trailing)
        }
    }
}

private struct ServerLogSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Streaming Server Log").font(.headline)
            ScrollView {
                Text(app.server.log.isEmpty ? "No output (the server may have been started by another app)." : app.server.log.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 700, height: 460)
    }
}

struct LoginSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .login
    @State private var email = ""
    @State private var password = ""
    @State private var acceptTerms = false
    @State private var marketing = false
    @State private var isWorking = false
    @State private var error: String?

    enum Mode { case login, register }

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text(mode == .login ? "Log in to Stremio" : "Create a Stremio account")
                .font(.title2.bold())
            Picker("", selection: $mode) {
                Text("Log In").tag(Mode.login)
                Text("Sign Up").tag(Mode.register)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(spacing: 10) {
                TextField("Email", text: $email)
                    .textContentType(.username)
                SecureField("Password", text: $password)
                    .textContentType(mode == .login ? .password : .newPassword)
                    .onSubmit(submit)
            }
            .textFieldStyle(.roundedBorder)

            if mode == .register {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("I agree to the Terms of Service and Privacy Policy", isOn: $acceptTerms)
                    Toggle("Send me news and offers", isOn: $marketing)
                    HStack(spacing: 12) {
                        Link("Terms of Service", destination: URL(string: "https://www.stremio.com/tos")!)
                        Link("Privacy Policy", destination: URL(string: "https://www.stremio.com/privacy")!)
                    }
                    .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(Theme.danger)
                    .multilineTextAlignment(.center)
            }

            HStack {
                if mode == .login {
                    Link("Forgot password?", destination: URL(string: "https://www.strem.io/reset-password/")!)
                        .font(.callout)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(mode == .login ? "Log In" : "Sign Up", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
            if isWorking { ProgressView().controlSize(.small) }
        }
        .padding(28)
        .frame(width: 420)
    }

    private var canSubmit: Bool {
        !isWorking && email.contains("@") && !password.isEmpty && (mode == .login || acceptTerms)
    }

    private func submit() {
        guard canSubmit else { return }
        isWorking = true
        error = nil
        Task {
            do {
                if mode == .login {
                    try await app.login(email: email, password: password)
                } else {
                    try await app.register(email: email, password: password, marketing: marketing)
                }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isWorking = false
        }
    }
}
