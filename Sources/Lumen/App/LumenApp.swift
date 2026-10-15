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

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Thin overlay scroll bars that take no space and fade out when idle, even with a mouse attached
        // or "Show scroll bars: Always". This app-level setting overrides the system one for Lumen only.
        UserDefaults.standard.set("WhenScrolling", forKey: "AppleShowScrollBars")
    }

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
            Divider()
            Toggle("Incognito Mode", isOn: Binding(get: { app.profile.settings.incognito },
                                                   set: { app.profile.settings.incognito = $0 }))
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(after: .textEditing) {
            Button("Search") {
                app.section = .search
                app.searchFocusRequest += 1
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
                .navigationSplitViewColumnWidth(min: 190, ideal: 208, max: 260)
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
        .toolbar {
            // The Library's sync button lives here rather than in LibraryView so it stays left of the search field.
            if app.section == .library && (app.paths[.library] ?? []).isEmpty && app.profile.isLoggedIn {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await app.library.sync() }
                    } label: {
                        Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(app.library.isSyncing)
                    .help("Sync library with your Stremio account")
                }
            }
            if #available(macOS 26, *) {
                searchItem.sharedBackgroundVisibility(.hidden)
            } else {
                searchItem
            }
        }
        .background(Theme.background)
    }

    /// Replaces `.searchable` so the field matches the app's capsule inputs.
    private var searchItem: some ToolbarContent {
        @Bindable var app = app
        return ToolbarItem(placement: .primaryAction) {
            SearchField(prompt: "Search movies, series, channels", text: $app.searchQuery,
                        focusRequest: app.searchFocusRequest)
                .onSubmit { app.search(app.searchQuery) }
                // Clearing the field (✕, Esc or deleting the text) clears the results too.
                .onChange(of: app.searchQuery) { if app.searchQuery.isEmpty { app.submittedSearch = "" } }
                .frame(width: 300)
        }
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
            // Insets and the 27pt leading column follow Apple Music's account row.
            VStack(alignment: .leading, spacing: 16) {
                IncognitoSwitch()
                ServerStatusBadge()
                AccountBadge()
            }
            .padding(.leading, 18)
            .padding(.trailing, 16)
            .padding(.top, 12)
            .padding(.bottom, 15)
        }
    }
}

/// A plain `Label`, so the sidebar list style sets the font (13pt) and icon size. Apple Music's rows are
/// also indented one outline level and are 32pt apart instead of 28.5pt; the padding adds both.
private struct SidebarRow: View {
    var section: SidebarSection

    var body: some View {
        Label(section.title, systemImage: section.icon)
            .padding(.leading, 13)
            .padding(.vertical, 1.75)
    }
}

/// Width of the leading icon column in the sidebar's bottom area (Apple Music's account avatar size).
private let sidebarFooterIconWidth: CGFloat = 27

private struct IncognitoSwitch: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var profile = app.profile
        HStack(spacing: 7) {
            Image(systemName: profile.settings.incognito ? "eye.slash.fill" : "eye.slash")
                .font(.system(size: 13))
                .frame(width: sidebarFooterIconWidth)
            Text("Incognito")
                .font(.system(size: 12, weight: profile.settings.incognito ? .semibold : .regular))
            Spacer(minLength: 4)
            Toggle("Incognito", isOn: $profile.settings.incognito)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .foregroundStyle(profile.settings.incognito ? Theme.foreground : .secondary)
        .help("Don't keep searches or what you play: titles stay out of Continue Watching and aren't synced, "
            + "and search results and posters aren't cached on disk (⇧⌘N).")
    }
}

private struct ServerStatusBadge: View {
    @Environment(AppState.self) private var app

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .frame(width: sidebarFooterIconWidth)
            Text(label)
                .font(.system(size: 12))
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
            HStack(spacing: 7) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 27))
                    .foregroundStyle(Theme.accent)
                    .frame(width: sidebarFooterIconWidth)
                VStack(alignment: .leading, spacing: 1) {
                    Text(auth.user.email)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(app.library.isSyncing ? "Syncing…" : "Synced")
                        .font(.system(size: 11))
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
