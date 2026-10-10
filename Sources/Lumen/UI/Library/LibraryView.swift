import SwiftUI

struct LibraryView: View {
    @Environment(AppState.self) private var app
    @State private var typeFilter: String?
    @State private var sort: Sort = .lastWatched
    @State private var filterText = ""

    enum Sort: String, CaseIterable, Identifiable {
        case lastWatched = "Last watched"
        case name = "Name"
        case added = "Recently added"
        case timesWatched = "Most watched"
        case watched = "Watched"
        case notWatched = "Not watched"

        var id: String { rawValue }
    }

    private var items: [LibraryItem] {
        var items = app.library.libraryItems
        if let typeFilter { items = items.filter { $0.type == typeFilter } }
        if !filterText.isEmpty { items = items.filter { $0.name.localizedCaseInsensitiveContains(filterText) } }
        switch sort {
        case .lastWatched:
            return items.sorted { ($0.state.lastWatched ?? .distantPast) > ($1.state.lastWatched ?? .distantPast) }
        case .name:
            return items.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        case .added:
            return items.sorted { ($0.ctime ?? .distantPast) > ($1.ctime ?? .distantPast) }
        case .timesWatched:
            return items.sorted { $0.state.timesWatched > $1.state.timesWatched }
        case .watched:
            return items.filter(\.isWatched).sorted { ($0.state.lastWatched ?? .distantPast) > ($1.state.lastWatched ?? .distantPast) }
        case .notWatched:
            return items.filter { !$0.isWatched }.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        }
    }

    private let columns = [GridItem(.adaptive(minimum: Theme.posterWidth, maximum: Theme.posterWidth + 30), spacing: 20, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 8) {
                    Button { typeFilter = nil } label: { Chip(title: "All", isSelected: typeFilter == nil) }
                        .buttonStyle(.plain)
                    ForEach(app.library.types, id: \.self) { type in
                        Button { typeFilter = type } label: { Chip(title: Theme.typeTitle(type), isSelected: typeFilter == type) }
                            .buttonStyle(.plain)
                    }
                    Spacer()
                    SearchField(prompt: "Filter", text: $filterText)
                        .frame(width: 180)
                    Dropdown(title: "Sort", selection: $sort, label: sort.rawValue) {
                        ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .frame(width: 150)
                }
                .padding(.horizontal, 28)

                if !app.profile.isLoggedIn {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.badge.exclamationmark")
                            .font(.title2)
                        Text("You're not logged in. Your library is only stored on this Mac.")
                            .foregroundStyle(Theme.secondaryForeground)
                        Spacer()
                        Button("Log in") { app.showLogin = true }.buttonStyle(PrimaryButtonStyle())
                    }
                    .panelStyle()
                    .padding(.horizontal, 28)
                }

                if items.isEmpty {
                    EmptyStateView(icon: "books.vertical", title: "Your library is empty",
                                   message: "Add movies and series to your library from their detail page.")
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 26) {
                        ForEach(items) { item in
                            PosterCard(meta: item.preview, progress: item.isInContinueWatching ? item.progress : nil,
                                       isWatched: item.isWatched, subtitle: Theme.typeSingular(item.type)) {
                                app.openMeta(type: item.type, id: item.id)
                            }
                            .contextMenu {
                                Button("Details") { app.openMeta(type: item.type, id: item.id) }
                                if item.isInContinueWatching { Button("Resume") { app.resume(item) } }
                                Divider()
                                Button("Remove from Library", role: .destructive) { app.library.remove(item.id) }
                            }
                        }
                    }
                    .padding(.horizontal, 28)
                }
            }
            .padding(.vertical, 20)
        }
        .background(Theme.background)
        .navigationTitle("Library")
    }
}
