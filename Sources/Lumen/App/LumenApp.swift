import AppKit
import SwiftUI

@main
struct LumenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var app = AppState()

    var body: some Scene {
        Window("Lumen", id: "main") {
            RootView()
                .environment(app)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .frame(minWidth: 1000, minHeight: 640)
                .onOpenURL { app.handle(url: $0) }
                .task {
                    appDelegate.app = app
                    DebugHooks.app = app
                    for url in appDelegate.pendingURLs { app.handle(url: url) }
                    appDelegate.pendingURLs.removeAll()
                    await app.bootstrap()
                }
        }
        .defaultSize(width: 1360, height: 860)
        .windowToolbarStyle(.unified)
        .commands { LumenCommands(app: app) }

        Settings {
            SettingsView()
                .environment(app)
                .preferredColorScheme(.dark)
                .frame(width: 620, height: 680)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var app: AppState?
    var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // When run outside an .app bundle (swift run), make sure we become a regular app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DebugHooks.install()
        if Bundle.main.bundleIdentifier == nil || NSApp.applicationIconImage == nil {
            NSApp.applicationIconImage = NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: nil)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            if let app { urls.forEach(app.handle(url:)) } else { pendingURLs += urls }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { app?.shutdown() }
    }
}

struct LumenCommands: Commands {
    var app: AppState

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()
            ForEach(Array(SidebarSection.allCases.enumerated()), id: \.element) { index, section in
                Button(section.title) { app.section = section }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
            Divider()
            Button("Back") {
                if app.player != nil { app.closePlayer() } else if !(app.paths[app.section] ?? []).isEmpty {
                    app.paths[app.section]?.removeLast()
                }
            }
            .keyboardShortcut("[", modifiers: .command)
        }
        CommandGroup(after: .textEditing) {
            Button("Search") {
                app.section = .search
            }
            .keyboardShortcut("f", modifiers: .command)
        }
        CommandMenu("Playback") {
            Button("Open Link from Clipboard") {
                if let string = NSPasteboard.general.string(forType: .string), let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    app.handle(url: url)
                }
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Close Player") { app.closePlayer() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(app.player == nil)
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        ZStack {
            MainView()
                .opacity(app.player == nil ? 1 : 0)
                .allowsHitTesting(app.player == nil)
            if let player = app.player {
                PlayerView(session: player)
                    .id(player.id)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: app.player?.id)
        .toolbarVisibility(app.player == nil ? .automatic : .hidden, for: .windowToolbar)
        .toolbarBackgroundVisibility(app.player == nil ? .automatic : .hidden, for: .windowToolbar)
        .sheet(item: $app.pendingAddonInstall) { addon in
            InstallAddonSheet(addon: addon)
        }
        .sheet(isPresented: $app.showLogin) {
            LoginSheet()
        }
        .alert(item: $app.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
    }
}

struct MainView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            NavigationStack(path: app.path(for: app.section)) {
                sectionRoot(app.section)
                    .navigationDestination(for: Route.self) { route in
                        switch route {
                        case let .meta(type, id, preview):
                            MetaDetailView(type: type, id: id, preview: preview)
                        case let .catalog(transportUrl, type, catalogId, genre):
                            CatalogPageView(addonTransportUrl: transportUrl, type: type, catalogId: catalogId, genre: genre)
                        }
                    }
            }
            .id(app.section)
        }
        .searchable(text: $app.searchQuery, placement: .toolbar, prompt: "Search movies, series, channels")
        .onSubmit(of: .search) { app.search(app.searchQuery) }
        .background(Theme.background)
    }

    @ViewBuilder
    private func sectionRoot(_ section: SidebarSection) -> some View {
        switch section {
        case .board: BoardView()
        case .discover: DiscoverView()
        case .library: LibraryView()
        case .search: SearchView()
        case .addons: AddonsView()
        case .settings: SettingsView()
        }
    }
}

private struct Sidebar: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        List(selection: Binding(get: { app.section }, set: { if let value = $0 { app.section = value } })) {
            Section {
                ForEach(SidebarSection.allCases.filter { $0 != .settings }) { section in
                    SidebarRow(section: section).tag(section)
                }
            }
            Section {
                SidebarRow(section: .settings).tag(SidebarSection.settings)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                ServerStatusBadge()
                AccountBadge()
            }
            .padding(12)
        }
    }
}

private struct SidebarRow: View {
    var section: SidebarSection

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: section.icon)
                .font(.system(size: 15))
                .frame(width: 20)
            Text(section.title)
                .font(.system(size: 14, weight: .medium))
        }
        .padding(.vertical, 4)
    }
}

private struct ServerStatusBadge: View {
    @Environment(AppState.self) private var app

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .help("Streaming server (needed for torrents)")
        .onTapGesture { app.section = .settings }
    }

    private var color: Color {
        switch app.server.status {
        case .running: return Theme.green
        case .starting, .unknown: return Theme.yellow
        case .stopped, .failed: return Theme.danger
        }
    }

    private var label: String {
        switch app.server.status {
        case .running: return "Streaming server online"
        case .starting: return "Starting streaming server…"
        case .unknown: return "Checking streaming server…"
        case .stopped: return "Streaming server offline"
        case .failed: return "Streaming server error"
        }
    }
}

private struct AccountBadge: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if let auth = app.profile.auth {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 0) {
                    Text(auth.user.email)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(app.library.isSyncing ? "Syncing…" : "Synced")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Button {
                app.showLogin = true
            } label: {
                Label("Log In", systemImage: "person.crop.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }
}
