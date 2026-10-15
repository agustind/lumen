import SwiftUI

enum CatalogSort: String, CaseIterable, Identifiable {
    /// The order the addon returns.
    case catalog
    case imdbRating

    var id: String { rawValue }

    var title: String {
        switch self {
        case .catalog: return "Catalog order"
        case .imdbRating: return "IMDb rating"
        }
    }
}

/// Paginated catalog contents (`skip` extra) for Discover and "See all".
@MainActor
@Observable
final class CatalogGridModel {
    var items: [MetaItem] = []
    var isLoading = false
    var error: String?
    var canLoadMore = true
    private(set) var sort: CatalogSort = .catalog
    private var key: String?
    /// Key of the page request in flight, so a request for a previous selection doesn't block the next one.
    private var loadingKey: String?
    private var addon: AddonDescriptor?
    private var catalog: ManifestCatalog?
    private var extras: [(String, String)] = []
    private var seen: Set<String> = []

    /// Addons can't sort by rating, so the rating sort ranks this many titles from the start of the catalog
    /// and then stops loading. Sorting while pages keep arriving would move posters above the scroll position.
    static let ratingSortLimit = 300

    func configure(addon: AddonDescriptor, catalog: ManifestCatalog, extras: [(String, String)], sort: CatalogSort = .catalog) async {
        let newKey = "\(addon.transportUrl)|\(catalog.stableId)|\(extras.map { "\($0.0)=\($0.1)" }.joined(separator: "&"))|\(sort.rawValue)"
        guard newKey != key else { return }
        key = newKey
        self.addon = addon
        self.catalog = catalog
        self.extras = extras
        self.sort = sort
        items = []
        seen = []
        error = nil
        canLoadMore = true
        switch sort {
        case .catalog:
            await loadPage()
        case .imdbRating:
            while canLoadMore, items.count < Self.ratingSortLimit, key == newKey {
                let before = items.count
                await loadPage()
                if items.count == before { break }
            }
            if key == newKey { canLoadMore = false }
        }
    }

    /// Next page for infinite scroll. The rating sort loads its pages up front instead.
    func loadMore() async {
        guard sort == .catalog else { return }
        await loadPage()
    }

    private func loadPage() async {
        guard loadingKey != key, canLoadMore, let addon, let catalog else { return }
        let requestKey = key
        loadingKey = requestKey
        isLoading = true
        defer {
            if loadingKey == requestKey {
                loadingKey = nil
                isLoading = false
            }
        }
        var extra = extras
        if !items.isEmpty {
            guard catalog.extra(named: "skip") != nil else { canLoadMore = false; return }
            extra.append(("skip", String(items.count)))
        }
        do {
            let page = try await AddonClient.shared.catalog(addon: addon, catalog: catalog, extra: extra)
            guard requestKey == key else { return }
            let fresh = page.filter { seen.insert($0.id).inserted }
            items += fresh
            if sort == .imdbRating { items = Self.sortedByRating(items) }
            canLoadMore = !fresh.isEmpty && catalog.extra(named: "skip") != nil
        } catch {
            guard requestKey == key else { return }
            self.error = error.localizedDescription
            canLoadMore = false
        }
    }

    /// Highest IMDb rating first; unrated titles last. Ties keep the catalog order.
    static func sortedByRating(_ items: [MetaItem]) -> [MetaItem] {
        items.enumerated()
            .sorted { a, b in
                let ra = a.element.imdbRating.flatMap(Double.init) ?? -1
                let rb = b.element.imdbRating.flatMap(Double.init) ?? -1
                return ra != rb ? ra > rb : a.offset < b.offset
            }
            .map(\.element)
    }
}

struct PosterGrid: View {
    var items: [MetaItem]
    var isLoading: Bool
    var canLoadMore: Bool
    var onSelect: (MetaItem) -> Void
    var onLoadMore: () async -> Void

    private let columns = [GridItem(.adaptive(minimum: Theme.posterWidth, maximum: Theme.posterWidth + 30), spacing: 20, alignment: .top)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 26) {
            ForEach(items) { item in
                PosterCard(meta: item, subtitle: item.releaseInfo) { onSelect(item) }
                    .onAppear {
                        if item.id == items.last?.id { Task { await onLoadMore() } }
                    }
            }
        }
        .padding(.horizontal, 28)
        if isLoading {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding()
        }
    }
}

struct DiscoverView: View {
    @Environment(AppState.self) private var app
    @State private var model = CatalogGridModel()
    @State private var type: String = "movie"
    @State private var catalogKey: String?
    @State private var genre: String?
    @State private var sort: CatalogSort = .catalog

    private var catalogs: [(addon: AddonDescriptor, catalog: ManifestCatalog)] {
        app.profile.activeAddons.flatMap { addon in
            addon.manifest.catalogs
                .filter { catalog in catalog.requiredExtras.allSatisfy { $0.name == "genre" && !($0.options ?? []).isEmpty } }
                .map { (addon, $0) }
        }
    }

    private var types: [String] {
        var result: [String] = []
        for entry in catalogs where !result.contains(entry.catalog.type) { result.append(entry.catalog.type) }
        return result.sorted { LibraryStore.typeOrder($0) < LibraryStore.typeOrder($1) }
    }

    private var catalogsForType: [(addon: AddonDescriptor, catalog: ManifestCatalog)] {
        catalogs.filter { $0.catalog.type == type }
    }

    private func key(_ entry: (addon: AddonDescriptor, catalog: ManifestCatalog)) -> String {
        "\(entry.addon.transportUrl)|\(entry.catalog.id)"
    }

    private func catalogTitle(_ entry: (addon: AddonDescriptor, catalog: ManifestCatalog)) -> String {
        "\(entry.catalog.name ?? entry.catalog.id) · \(entry.addon.manifest.name)"
    }

    private var selected: (addon: AddonDescriptor, catalog: ManifestCatalog)? {
        catalogsForType.first { key($0) == catalogKey } ?? catalogsForType.first
    }

    private var genreExtra: ExtraProp? { selected?.catalog.extra(named: "genre") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if sort == .imdbRating, !model.items.isEmpty {
                    Text("The first \(model.items.count) titles of this catalog, highest IMDb rating first.")
                        .font(.callout)
                        .foregroundStyle(Theme.secondaryForeground)
                        .padding(.horizontal, 28)
                }
                if let error = model.error, model.items.isEmpty {
                    EmptyStateView(icon: "exclamationmark.triangle", title: "Couldn't load catalog", message: error)
                } else if !model.isLoading && model.items.isEmpty {
                    EmptyStateView(icon: "film.stack", title: "Nothing here", message: "This catalog returned no items.")
                } else {
                    PosterGrid(items: model.items, isLoading: model.isLoading, canLoadMore: model.canLoadMore,
                               onSelect: { app.openMeta($0) }, onLoadMore: { await model.loadMore() })
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        // The filters stay pinned above the grid; posters scroll underneath.
        .safeAreaInset(edge: .top, spacing: 0) {
            filterBar
                .padding(.top, 20)
                .padding(.bottom, 12)
                .background(.ultraThinMaterial)
                .background(Theme.background.opacity(0.6))
        }
        .background(Theme.background)
        .navigationTitle("Discover")
        .task(id: reloadKey) { await reload() }
        .onAppear(perform: applyPendingSelection)
        .onChange(of: app.discoverSelection) { applyPendingSelection() }
    }

    private var reloadKey: String { "\(type)|\(catalogKey ?? "")|\(genre ?? "")|\(sort.rawValue)|\(app.profile.activeAddons.count)" }

    private func reload() async {
        guard let selected else { return }
        var extras: [(String, String)] = []
        if let genre { extras.append(("genre", genre)) }
        else if let required = genreExtra, required.isRequired, let first = required.options?.first {
            genre = first
            return
        }
        await model.configure(addon: selected.addon, catalog: selected.catalog, extras: extras, sort: sort)
    }

    private func applyPendingSelection() {
        guard let selection = app.discoverSelection else { return }
        app.discoverSelection = nil
        type = selection.type
        if let match = catalogs.first(where: {
            ($0.addon.transportUrl == selection.addonTransportUrl || $0.addon.manifest.id == selection.addonTransportUrl)
                && $0.catalog.type == selection.type && $0.catalog.id == selection.catalogId
        }) {
            catalogKey = key(match)
        }
        genre = selection.genre
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            Dropdown(title: "Type", selection: $type, label: Theme.typeTitle(type)) {
                ForEach(types, id: \.self) { Text(Theme.typeTitle($0)).tag($0) }
            }
            .frame(width: 160)
            .onChange(of: type) { catalogKey = nil; genre = nil }

            Dropdown(title: "Catalog",
                     selection: Binding(get: { selected.map(key) ?? "" }, set: { catalogKey = $0; genre = nil }),
                     label: selected.map(catalogTitle) ?? "Catalog") {
                ForEach(catalogsForType, id: \.catalog.id) { entry in
                    Text(catalogTitle(entry)).tag(key(entry))
                }
            }
            .frame(maxWidth: 320)

            if let genreExtra, let options = genreExtra.options, !options.isEmpty {
                Dropdown(title: "Genre", selection: $genre, label: genre ?? "All genres") {
                    if !genreExtra.isRequired { Text("All genres").tag(String?.none) }
                    ForEach(options, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .frame(width: 200)
            }

            Dropdown(title: "Sort", selection: $sort, label: sort.title) {
                ForEach(CatalogSort.allCases) { Text($0.title).tag($0) }
            }
            .frame(width: 170)
            Spacer()
        }
        .padding(.horizontal, 28)
    }
}

/// Full catalog page opened from a Board row's "See All".
struct CatalogPageView: View {
    @Environment(AppState.self) private var app
    var addonTransportUrl: String
    var type: String
    var catalogId: String
    var genre: String?
    @State private var model = CatalogGridModel()

    private var entry: (AddonDescriptor, ManifestCatalog)? {
        guard let addon = app.profile.activeAddons.first(where: { $0.transportUrl == addonTransportUrl }),
              let catalog = addon.manifest.catalogs.first(where: { $0.type == type && $0.id == catalogId }) else { return nil }
        return (addon, catalog)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let entry {
                    Text("\(entry.1.name ?? entry.1.id) – \(Theme.typeSingular(type))")
                        .font(.system(size: 26, weight: .bold))
                        .padding(.horizontal, 28)
                }
                PosterGrid(items: model.items, isLoading: model.isLoading, canLoadMore: model.canLoadMore,
                           onSelect: { app.openMeta($0) }, onLoadMore: { await model.loadMore() })
            }
            .padding(.vertical, 20)
        }
        .background(Theme.background)
        .navigationTitle(entry?.1.name ?? "Catalog")
        .task {
            guard let entry else { return }
            await model.configure(addon: entry.0, catalog: entry.1, extras: genre.map { [("genre", $0)] } ?? [])
        }
    }
}
