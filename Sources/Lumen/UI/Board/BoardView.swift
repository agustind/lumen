import SwiftUI

/// One catalog preview row (shared by Board and Search).
struct CatalogRowModel: Identifiable {
    var addon: AddonDescriptor
    var catalog: ManifestCatalog
    var items: [MetaItem] = []
    var isLoading = true
    var error: String?

    var id: String { "\(addon.transportUrl)|\(catalog.type)|\(catalog.id)" }

    var title: String { catalog.name ?? catalog.id }
}

@MainActor
@Observable
final class BoardModel {
    var rows: [CatalogRowModel] = []
    private var loadedSignature: [String] = []

    func load(addons: [AddonDescriptor], force: Bool = false) async {
        let catalogs = addons.flatMap { addon in
            addon.manifest.catalogs.filter(\.isBoardCatalog).map { (addon, $0) }
        }
        let signature = catalogs.map { "\($0.0.transportUrl)|\($0.1.stableId)" }
        guard force || signature != loadedSignature else { return }
        loadedSignature = signature
        rows = catalogs.map { CatalogRowModel(addon: $0.0, catalog: $0.1) }

        await forEachConcurrently(rows) { row -> Result<[MetaItem], Error> in
            do {
                return .success(try await AddonClient.shared.catalog(addon: row.addon, catalog: row.catalog))
            } catch {
                return .failure(error)
            }
        } onResult: { row, result in
            guard let index = self.rows.firstIndex(where: { $0.id == row.id }) else { return }
            self.rows[index].isLoading = false
            switch result {
            case .success(let items): self.rows[index].items = items
            case .failure(let error): self.rows[index].error = error.localizedDescription
            }
        }
    }
}

struct BoardView: View {
    @Environment(AppState.self) private var app
    @State private var model = BoardModel()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 34) {
                if let hero = heroItem {
                    BoardHero(meta: hero)
                }

                let continueWatching = app.library.continueWatching
                if !continueWatching.isEmpty {
                    ContinueWatchingRow(items: continueWatching)
                }

                ForEach(model.rows) { row in
                    // Rows that failed or came back empty are hidden, like stremio-web does.
                    if row.isLoading || !row.items.isEmpty {
                        CatalogRow(
                            title: row.title,
                            subtitle: Theme.typeSingular(row.catalog.type),
                            items: row.items,
                            isLoading: row.isLoading,
                            onSelect: { app.openMeta($0) },
                            onSeeAll: {
                                app.push(.catalog(addonTransportUrl: row.addon.transportUrl, type: row.catalog.type,
                                                  catalogId: row.catalog.id, genre: nil))
                            }
                        )
                    }
                }
            }
            .padding(.bottom, 40)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .task(id: app.profile.activeAddons.map(\.transportUrl)) {
            await model.load(addons: app.profile.activeAddons)
        }
        .refreshable { await model.load(addons: app.profile.activeAddons, force: true) }
        .navigationTitle("Board")
    }

    /// The first item of the first loaded catalog that has artwork.
    private var heroItem: MetaItem? {
        model.rows.lazy.flatMap(\.items).first { $0.background != nil || $0.poster != nil }
    }
}

private struct BoardHero: View {
    @Environment(AppState.self) private var app
    var meta: MetaItem

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CachedImage(url: meta.background ?? meta.poster)
                .frame(height: 380)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay(
                    LinearGradient(colors: [.clear, Theme.background.opacity(0.6), Theme.background],
                                   startPoint: .top, endPoint: .bottom)
                )
                .overlay(
                    LinearGradient(colors: [Theme.background.opacity(0.85), .clear], startPoint: .leading, endPoint: .center)
                )

            VStack(alignment: .leading, spacing: 14) {
                if let logo = meta.logo {
                    CachedImage(url: logo, contentMode: .fit) { Color.clear }
                        .frame(maxWidth: 360, maxHeight: 110, alignment: .leading)
                } else {
                    Text(meta.name).font(.system(size: 40, weight: .heavy))
                }
                HStack(spacing: 10) {
                    if let rating = meta.imdbRating, !rating.isEmpty {
                        Label(rating, systemImage: "star.fill").foregroundStyle(Theme.yellow)
                    }
                    if let year = meta.releaseInfo { Text(year) }
                    Text(Theme.typeSingular(meta.type))
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.secondaryForeground)
                if let description = meta.description {
                    Text(description)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.secondaryForeground)
                        .lineLimit(3)
                        .frame(maxWidth: 560, alignment: .leading)
                }
                HStack(spacing: 10) {
                    Button { app.openMeta(meta) } label: {
                        Label("Watch now", systemImage: "play.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    Button { app.library.toggle(meta) } label: {
                        Label(app.library.isInLibrary(meta.id) ? "In library" : "Add to library",
                              systemImage: app.library.isInLibrary(meta.id) ? "checkmark" : "plus")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 8)
        }
    }
}

private struct ContinueWatchingRow: View {
    @Environment(AppState.self) private var app
    var items: [LibraryItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Continue Watching")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(Theme.foreground)
                .padding(.horizontal, 28)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(items) { item in
                        PosterCard(meta: item.preview, progress: item.progress, subtitle: episodeLabel(item)) {
                            app.resume(item)
                        }
                        .contextMenu {
                            Button("Resume") { app.resume(item) }
                            Button("Details") { app.openMeta(type: item.type, id: item.id) }
                            Divider()
                            Button("Dismiss from Continue Watching") { app.library.dismissFromContinueWatching(item.id) }
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 8)
            }
            .scrollClipDisabled()
        }
    }

    private func episodeLabel(_ item: LibraryItem) -> String? {
        guard let videoId = item.state.videoId, videoId != item.id else { return nil }
        // Series video ids look like "tt0903747:1:2".
        let parts = videoId.split(separator: ":")
        if parts.count >= 3, let season = Int(parts[parts.count - 2]), let episode = Int(parts[parts.count - 1]) {
            return "S\(season) E\(episode)"
        }
        return nil
    }
}
