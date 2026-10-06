import SwiftUI

@MainActor
@Observable
final class SearchModel {
    var rows: [CatalogRowModel] = []
    private(set) var query = ""
    private var searchTask: Task<Void, Never>?

    func search(_ query: String, addons: [AddonDescriptor]) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != self.query else { return }
        self.query = trimmed
        searchTask?.cancel()
        guard !trimmed.isEmpty else {
            rows = []
            return
        }
        let catalogs = addons.flatMap { addon in addon.manifest.catalogs.filter(\.isSearchCatalog).map { (addon, $0) } }
        rows = catalogs.map { CatalogRowModel(addon: $0.0, catalog: $0.1) }
        searchTask = Task {
            await forEachConcurrently(rows) { row -> Result<[MetaItem], Error> in
                do {
                    return .success(try await AddonClient.shared.catalog(addon: row.addon, catalog: row.catalog, extra: [("search", trimmed)]))
                } catch {
                    return .failure(error)
                }
            } onResult: { row, result in
                guard self.query == trimmed, let index = self.rows.firstIndex(where: { $0.id == row.id }) else { return }
                self.rows[index].isLoading = false
                switch result {
                case .success(let items): self.rows[index].items = items
                case .failure(let error): self.rows[index].error = error.localizedDescription
                }
            }
        }
    }
}

struct SearchView: View {
    @Environment(AppState.self) private var app
    @State private var model = SearchModel()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 32) {
                if model.query.isEmpty {
                    EmptyStateView(icon: "magnifyingglass", title: "Search Lumen",
                                   message: "Type in the search field to find movies, series and channels across your addons.")
                        .frame(minHeight: 400)
                } else {
                    let visible = model.rows.filter { $0.isLoading || !$0.items.isEmpty }
                    if visible.isEmpty {
                        EmptyStateView(icon: "questionmark.square.dashed", title: "No results",
                                       message: "Nothing matched “\(model.query)”.")
                            .frame(minHeight: 400)
                    }
                    ForEach(visible) { row in
                        CatalogRow(title: "\(row.title) – \(Theme.typeSingular(row.catalog.type))",
                                   subtitle: row.addon.manifest.name,
                                   items: row.items, isLoading: row.isLoading,
                                   onSelect: { app.openMeta($0) })
                    }
                }
            }
            .padding(.vertical, 24)
        }
        .background(Theme.background)
        .navigationTitle(model.query.isEmpty ? "Search" : "Results for “\(model.query)”")
        .task(id: app.submittedSearch) {
            model.search(app.submittedSearch, addons: app.profile.activeAddons)
        }
    }
}
