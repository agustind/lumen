import AppKit
import SwiftUI

@MainActor
@Observable
final class AddonCatalogModel {
    var addons: [AddonDescriptor] = []
    var isLoading = false
    var error: String?
    private var loadedKey: String?

    /// Loads an `addon_catalog` (e.g. Cinemeta's "official"/"community" lists).
    func load(source: AddonDescriptor, catalog: ManifestCatalog) async {
        let key = "\(source.transportUrl)|\(catalog.stableId)"
        guard key != loadedKey else { return }
        loadedKey = key
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            addons = try await AddonClient.shared.addonCatalog(addon: source, catalog: catalog)
        } catch {
            addons = []
            self.error = error.localizedDescription
        }
    }
}

struct AddonsView: View {
    @Environment(AppState.self) private var app
    @State private var tab: Tab = .installed
    @State private var filter = ""
    @State private var typeFilter: String?
    @State private var catalogModel = AddonCatalogModel()
    @State private var addonURL = ""
    @State private var showAddURL = false

    enum Tab: Hashable {
        case installed
        case remote(source: String, catalogId: String, name: String)
    }

    /// Addon catalogs offered by installed addons (Cinemeta provides "Official" and "Community").
    private var remoteCatalogs: [(addon: AddonDescriptor, catalog: ManifestCatalog)] {
        var seen = Set<String>()
        return app.profile.activeAddons.flatMap { addon in
            addon.manifest.addonCatalogs.compactMap { catalog in
                let key = "\(addon.transportUrl)|\(catalog.id)"
                guard seen.insert(key).inserted else { return nil }
                return (addon, catalog)
            }
        }
    }

    private var currentList: [AddonDescriptor] {
        let base: [AddonDescriptor]
        switch tab {
        case .installed: base = app.profile.addons
        case .remote: base = catalogModel.addons
        }
        return base.filter { addon in
            (filter.isEmpty
                || addon.manifest.name.localizedCaseInsensitiveContains(filter)
                || (addon.manifest.description ?? "").localizedCaseInsensitiveContains(filter))
                && (typeFilter == nil || addon.manifest.types.contains(typeFilter!))
                && (app.profile.settings.showAdultAddons || !addon.manifest.behaviorHints.adult)
        }
    }

    private var availableTypes: [String] {
        let all = Set((tab == .installed ? app.profile.addons : catalogModel.addons).flatMap(\.manifest.types))
        return all.sorted { LibraryStore.typeOrder($0) < LibraryStore.typeOrder($1) }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.3)
            ScrollView {
                LazyVStack(spacing: 10) {
                    if case .remote = tab, catalogModel.isLoading {
                        ProgressView().padding(40)
                    } else if case .remote = tab, let error = catalogModel.error {
                        EmptyStateView(icon: "wifi.exclamationmark", title: "Couldn't load addons", message: error)
                    } else if currentList.isEmpty {
                        EmptyStateView(icon: "puzzlepiece.extension", title: "No addons", message: filter.isEmpty ? nil : "Nothing matches “\(filter)”.")
                    }
                    ForEach(currentList) { addon in
                        AddonRow(addon: addon, isInstalledTab: tab == .installed)
                    }
                }
                .padding(24)
            }
        }
        .background(Theme.background)
        .navigationTitle("Addons")
        .task(id: tab) {
            if case let .remote(source, catalogId, _) = tab,
               let entry = remoteCatalogs.first(where: { $0.addon.transportUrl == source && $0.catalog.id == catalogId }) {
                await catalogModel.load(source: entry.addon, catalog: entry.catalog)
            }
        }
        .sheet(isPresented: $showAddURL) {
            AddAddonURLSheet(url: $addonURL) { url in
                showAddURL = false
                app.requestInstall(transportUrl: url)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Source", selection: $tab) {
                Text("Installed").tag(Tab.installed)
                ForEach(remoteCatalogs.filter { $0.catalog.type == "all" }, id: \.catalog.id) { entry in
                    let name = entry.catalog.name ?? entry.catalog.id
                    Text(name).tag(Tab.remote(source: entry.addon.transportUrl, catalogId: entry.catalog.id, name: name))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Picker("Type", selection: $typeFilter) {
                Text("All types").tag(String?.none)
                ForEach(availableTypes, id: \.self) { Text(Theme.typeTitle($0)).tag(String?.some($0)) }
            }
            .labelsHidden()
            .frame(width: 140)

            Spacer()

            TextField("Search addons", text: $filter)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)

            Button {
                addonURL = ""
                showAddURL = true
            } label: {
                Label("Add Addon", systemImage: "plus")
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }
}

private struct AddonRow: View {
    @Environment(AppState.self) private var app
    var addon: AddonDescriptor
    var isInstalledTab: Bool
    @State private var isWorking = false

    private var installed: AddonDescriptor? {
        app.profile.addons.first { $0.transportUrl == addon.transportUrl || $0.manifest.id == addon.manifest.id }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            AddonLogo(url: addon.manifest.logo)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(addon.manifest.name)
                        .font(.system(size: 15, weight: .bold))
                    Text("v\(addon.manifest.version)")
                        .font(.caption)
                        .foregroundStyle(Theme.tertiaryForeground)
                    if addon.flags.official {
                        Text("OFFICIAL")
                            .font(.system(size: 9, weight: .heavy))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Theme.accent.opacity(0.4), in: Capsule())
                    }
                    if addon.isLegacy {
                        Text("UNSUPPORTED")
                            .font(.system(size: 9, weight: .heavy))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Theme.danger.opacity(0.5), in: Capsule())
                    }
                }
                if let description = addon.manifest.description {
                    Text(description)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.secondaryForeground)
                        .lineLimit(3)
                }
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryForeground)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 8) {
                buttons
            }
        }
        .panelStyle()
        .contextMenu {
            Button("Copy Manifest URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(addon.transportUrl, forType: .string)
            }
        }
    }

    private var summary: String {
        let types = addon.manifest.types.map(Theme.typeTitle).joined(separator: ", ")
        let resources = addon.manifest.resourceNames.joined(separator: ", ")
        return [types, resources].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder
    private var buttons: some View {
        if let installed {
            if let configure = installed.configureURL {
                Button("Configure") { NSWorkspace.shared.open(configure) }
                    .buttonStyle(SecondaryButtonStyle())
            }
            if !installed.flags.protected {
                Button(isWorking ? "Removing…" : "Uninstall") {
                    isWorking = true
                    Task {
                        await app.profile.uninstall(installed)
                        isWorking = false
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(isWorking)
            } else {
                Text("Installed")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.tertiaryForeground)
            }
        } else if addon.manifest.behaviorHints.configurationRequired, let configure = addon.configureURL {
            Button("Configure") { NSWorkspace.shared.open(configure) }
                .buttonStyle(PrimaryButtonStyle())
        } else {
            Button("Install") { app.pendingAddonInstall = addon }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(addon.isLegacy)
        }
    }
}

struct AddonLogo: View {
    var url: URL?
    var size: CGFloat = 64

    var body: some View {
        CachedImage(url: url, contentMode: .fit) {
            ZStack {
                Theme.surface
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: size * 0.4))
                    .foregroundStyle(Theme.tertiaryForeground)
            }
        }
        .frame(width: size, height: size)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct AddAddonURLSheet: View {
    @Binding var url: String
    var onSubmit: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Addon").font(.title2.bold())
            Text("Paste the addon's manifest URL (it usually ends in /manifest.json).")
                .foregroundStyle(.secondary)
            TextField("https://example.com/manifest.json", text: $url)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Continue", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func submit() {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
    }
}

/// Confirmation sheet shown before installing an addon (from the UI or a stremio:// link).
struct InstallAddonSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    var addon: AddonDescriptor
    @State private var isInstalling = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                AddonLogo(url: addon.manifest.logo, size: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text(addon.manifest.name).font(.title2.bold())
                    Text("Version \(addon.manifest.version)").foregroundStyle(.secondary)
                    Text(addon.transportUrl)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            if let description = addon.manifest.description {
                Text(description)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Types").foregroundStyle(.secondary)
                    Text(addon.manifest.types.map(Theme.typeTitle).joined(separator: ", "))
                }
                GridRow {
                    Text("Provides").foregroundStyle(.secondary)
                    Text(addon.manifest.resourceNames.joined(separator: ", "))
                }
                if !addon.manifest.catalogs.isEmpty {
                    GridRow {
                        Text("Catalogs").foregroundStyle(.secondary)
                        Text(addon.manifest.catalogs.map { $0.name ?? $0.id }.joined(separator: ", ")).lineLimit(3)
                    }
                }
            }
            .font(.callout)
            Text("Addons are made by third parties. Only install addons you trust.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                if addon.isConfigurable, let configure = addon.configureURL {
                    Button("Configure…") { NSWorkspace.shared.open(configure) }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(app.profile.isInstalled(addon) ? "Update" : "Install") {
                    isInstalling = true
                    Task {
                        await app.profile.install(addon)
                        isInstalling = false
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isInstalling || addon.isLegacy)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
