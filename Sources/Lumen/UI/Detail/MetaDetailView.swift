import AppKit
import SwiftUI

struct MetaDetailView: View {
    @Environment(AppState.self) private var app
    @State private var model: MetaDetailModel

    init(type: String, id: String, preview: MetaItem?) {
        _model = State(initialValue: MetaDetailModel(type: type, id: id, preview: preview))
    }

    var body: some View {
        ZStack {
            backdrop
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    if let meta = model.meta {
                        MetaInfoColumn(meta: meta, model: model)
                            .padding(36)
                            .frame(maxWidth: 760, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if model.isLoadingRecommendations || !model.recommendations.isEmpty {
                            // CatalogRow pads its content by 28pt; 8 more lines it up with the info column.
                            CatalogRow(title: "You might also like", subtitle: model.recommendationsSource,
                                       items: model.recommendations, isLoading: model.isLoadingRecommendations,
                                       onSelect: { app.openMeta($0) })
                                .padding(.leading, 8)
                                .padding(.bottom, 36)
                        }
                    } else if model.isLoadingMeta {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 400)
                    } else {
                        EmptyStateView(icon: "exclamationmark.triangle", title: "Couldn't load details", message: model.metaError)
                    }
                }
                .scrollContentBackground(.hidden)

                sidePanel
                    .frame(width: 430)
                    .background(.ultraThinMaterial)
                    .background(Theme.modalBackground.opacity(0.55))
            }
        }
        .background(Theme.background)
        .navigationTitle(model.meta?.name ?? "")
        .task { await model.load(profile: app.profile, library: app.library) }
    }

    private var backdrop: some View {
        GeometryReader { geo in
            CachedImage(url: model.meta?.background ?? model.meta?.poster) { Theme.background }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .overlay(Theme.background.opacity(0.55))
                .overlay(
                    LinearGradient(colors: [Theme.background.opacity(0.95), Theme.background.opacity(0.3)],
                                   startPoint: .leading, endPoint: .trailing)
                )
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var sidePanel: some View {
        if let meta = model.meta, model.isSeries, model.selectedVideoId == nil {
            EpisodesPanel(meta: meta, model: model)
        } else if model.selectedVideoId != nil {
            StreamsPanel(model: model)
        } else if model.isLoadingMeta {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyStateView(icon: "play.slash", title: "Nothing to play")
        }
    }
}

// MARK: - Info

private struct MetaInfoColumn: View {
    @Environment(AppState.self) private var app
    var meta: MetaItem
    var model: MetaDetailModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let logo = meta.logo {
                CachedImage(url: logo, contentMode: .fit) {
                    Text(meta.name).font(.system(size: 40, weight: .heavy))
                }
                .frame(maxWidth: 420, maxHeight: 140, alignment: .leading)
            } else {
                Text(meta.name)
                    .font(.system(size: 40, weight: .heavy))
                    .foregroundStyle(Theme.foreground)
            }

            HStack(spacing: 14) {
                if let runtime = meta.runtime { Text(runtime) }
                if let releaseInfo = meta.releaseInfo { Text(releaseInfo) }
                if let rating = meta.rating {
                    HStack(spacing: 4) {
                        Text("IMDb")
                            .font(.system(size: 10, weight: .black))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Theme.yellow, in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.black)
                        Text(rating)
                    }
                    .onTapGesture { if let url = meta.imdbURL { NSWorkspace.shared.open(url) } }
                }
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.secondaryForeground)

            actionButtons

            if let description = meta.description {
                Text(description)
                    .font(.system(size: 15))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.foreground.opacity(0.85))
                    .textSelection(.enabled)
            }

            if !meta.allGenres.isEmpty {
                LinkSection(title: "Genres", names: meta.allGenres) { name in
                    if let link = meta.links.first(where: { $0.category == "Genres" && $0.name == name }) {
                        app.handleLinkFromMeta(link)
                    }
                }
            }
            if !meta.allCast.isEmpty {
                LinkSection(title: "Cast", names: Array(meta.allCast.prefix(12))) { app.search($0) }
            }
            if !meta.allDirectors.isEmpty {
                LinkSection(title: "Directors", names: meta.allDirectors) { app.search($0) }
            }
            if !meta.allWriters.isEmpty {
                LinkSection(title: "Writers", names: Array(meta.allWriters.prefix(6))) { app.search($0) }
            }
        }
    }

    private var libraryItem: LibraryItem? { app.library.item(meta.id) }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 10) {
            if let item = libraryItem, item.isInContinueWatching {
                Button {
                    app.resume(item)
                } label: {
                    Label(resumeLabel(item), systemImage: "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
            }

            let inLibrary = app.library.isInLibrary(meta.id)
            Button {
                app.library.toggle(meta)
            } label: {
                Label(inLibrary ? "In Library" : "Add to Library", systemImage: inLibrary ? "checkmark" : "plus")
            }
            .buttonStyle(SecondaryButtonStyle())

            if let trailer = meta.trailerStreams.first {
                Button {
                    playTrailer(trailer)
                } label: {
                    Label("Trailer", systemImage: "film")
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            if meta.videos.isEmpty {
                let watched = libraryItem?.isWatched ?? false
                Button {
                    app.library.markWatched(meta, watched: !watched)
                } label: {
                    Label(watched ? "Watched" : "Mark as watched", systemImage: watched ? "eye.fill" : "eye")
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            Menu {
                if let url = meta.imdbURL {
                    Button("Open on IMDb") { NSWorkspace.shared.open(url) }
                }
                Button("Copy Stremio Link") {
                    copy("stremio:///detail/\(meta.type)/\(AddonClient.encodeComponent(meta.id))")
                }
                if let share = meta.links.first(where: { $0.category == "share" })?.url {
                    Button("Copy Share Link") { copy(share.absoluteString) }
                }
                if !meta.videos.isEmpty {
                    Divider()
                    Button("Mark All as Watched") { app.library.markWatched(meta, watched: true) }
                    Button("Mark All as Unwatched") { app.library.markWatched(meta, watched: false) }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(IconButtonStyle())
            .fixedSize()
        }
    }

    private func resumeLabel(_ item: LibraryItem) -> String {
        if let videoId = item.state.videoId, let video = meta.videos.first(where: { $0.id == videoId }),
           let season = video.season, let episode = video.episode {
            return "Resume S\(season)E\(episode)"
        }
        return "Resume"
    }

    private func playTrailer(_ trailer: Stream) {
        if case .youTube(let id) = trailer.source, !app.server.status.isRunning {
            NSWorkspace.shared.open(URL(string: "https://www.youtube.com/watch?v=\(id)")!)
            return
        }
        app.play(PlaybackRequest(stream: trailer, meta: nil))
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

private struct LinkSection: View {
    var title: String
    var names: [String]
    var action: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(1)
                .foregroundStyle(Theme.tertiaryForeground)
            FlowLayout(spacing: 6) {
                ForEach(names, id: \.self) { name in
                    Button { action(name) } label: { Chip(title: name) }
                        .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Wrapping horizontal layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                let previous = rows[rows.count - 1]
                rows.append(Row(y: previous.y + previous.height + spacing))
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

// MARK: - Episodes

private struct EpisodesPanel: View {
    @Environment(AppState.self) private var app
    var meta: MetaItem
    var model: MetaDetailModel

    var body: some View {
        VStack(spacing: 0) {
            if meta.isSeriesLike && meta.seasons.count > 1 {
                HStack {
                    Picker("Season", selection: Binding(get: { model.selectedSeason ?? meta.seasons.first ?? 1 },
                                                        set: { model.selectedSeason = $0 })) {
                        ForEach(meta.seasons, id: \.self) { season in
                            Text(season == 0 ? "Specials" : "Season \(season)").tag(season)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                    Spacer()
                    Menu {
                        Button("Mark Season as Watched") { app.library.markVideos(seasonVideos, of: meta, watched: true) }
                        Button("Mark Season as Unwatched") { app.library.markVideos(seasonVideos, of: meta, watched: false) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .padding(16)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        let watched = app.library.watchedBitField(for: meta)
                        let currentId = app.library.item(meta.id)?.state.videoId
                        ForEach(seasonVideos) { video in
                            EpisodeRow(video: video, isWatched: watched?.isWatched(video.id) ?? false,
                                       isCurrent: video.id == currentId) {
                                model.selectVideo(video.id, profile: app.profile)
                            }
                            .id(video.id)
                            .contextMenu {
                                let isWatched = watched?.isWatched(video.id) ?? false
                                Button(isWatched ? "Mark as Unwatched" : "Mark as Watched") {
                                    app.library.markVideos([video], of: meta, watched: !isWatched)
                                }
                                Button("Mark Previous as Watched") {
                                    let ordered = meta.orderedVideos
                                    if let index = ordered.firstIndex(where: { $0.id == video.id }) {
                                        app.library.markVideos(Array(ordered[...index]), of: meta, watched: true)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 16)
                }
                .onAppear {
                    if let current = app.library.item(meta.id)?.state.videoId { proxy.scrollTo(current, anchor: .center) }
                }
            }
        }
    }

    private var seasonVideos: [Video] {
        if meta.isSeriesLike {
            return meta.videos(inSeason: model.selectedSeason ?? meta.seasons.first ?? 1)
        }
        return meta.videos.sorted { ($0.released ?? .distantPast) > ($1.released ?? .distantPast) }
    }
}

private struct EpisodeRow: View {
    var video: Video
    var isWatched: Bool
    var isCurrent: Bool
    var action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                CachedImage(url: video.thumbnail) {
                    ZStack {
                        Theme.surface
                        Image(systemName: "play.rectangle").foregroundStyle(Theme.tertiaryForeground)
                    }
                }
                .frame(width: 128, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if isWatched {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Theme.green)
                            .padding(4)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.foreground)
                        .lineLimit(2)
                    if let released = video.released {
                        Text(video.isReleased ? Format.releaseDate.string(from: released) : "Upcoming · \(Format.releaseDate.string(from: released))")
                            .font(.system(size: 11))
                            .foregroundStyle(video.isReleased ? Theme.tertiaryForeground : Theme.yellow)
                    }
                    if let overview = video.overview {
                        Text(overview)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.secondaryForeground)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isCurrent ? Theme.accent.opacity(0.25) : (isHovered ? Color.white.opacity(0.08) : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var title: String {
        let name = video.title.isEmpty ? "Episode \(video.episode ?? 0)" : video.title
        if let episode = video.episode { return "\(episode). \(name)" }
        return name
    }
}

// MARK: - Streams

private struct StreamsPanel: View {
    @Environment(AppState.self) private var app
    var model: MetaDetailModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.streamGroups.isEmpty {
                EmptyStateView(icon: "puzzlepiece.extension", title: "No stream addons",
                               message: "Install an addon that provides streams for this content from the Addons section.")
            } else if model.visibleGroups.isEmpty && !model.isLoadingStreams {
                EmptyStateView(icon: "play.slash", title: "No streams found",
                               message: "None of your addons returned streams for this item.")
            } else {
                addonFilterBar
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(model.visibleGroups) { group in
                            ForEach(group.streams) { stream in
                                StreamRow(stream: stream, addonName: group.addon.manifest.name) {
                                    play(stream, addon: group.addon)
                                }
                                .contextMenu { contextMenu(stream) }
                            }
                        }
                        if model.isLoadingStreams {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Loading streams from \(model.streamGroups.filter(\.isLoading).map(\.addon.manifest.name).joined(separator: ", "))…")
                                    .font(.caption)
                                    .foregroundStyle(Theme.tertiaryForeground)
                            }
                            .padding(12)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 16)
                }
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        if let meta = model.meta, model.isSeries, meta.videos.count > 1 {
            HStack(spacing: 10) {
                Button {
                    model.selectVideo(nil, profile: app.profile)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(IconButtonStyle(size: 30))
                VStack(alignment: .leading, spacing: 2) {
                    if let video = model.selectedVideo {
                        Text(video.season.map { "S\($0) E\(video.episode ?? 0)" } ?? "")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.tertiaryForeground)
                        Text(video.title)
                            .font(.headline)
                            .lineLimit(1)
                    }
                }
                Spacer()
                reloadButton
            }
            .padding(16)
        } else {
            HStack {
                Text("Streams").font(.headline)
                Spacer()
                reloadButton
            }
            .padding(16)
        }
    }

    private var reloadButton: some View {
        Button {
            model.reloadStreams(profile: app.profile)
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .help("Reload streams")
    }

    @ViewBuilder
    private var addonFilterBar: some View {
        let groups = model.streamGroups.filter { !$0.streams.isEmpty }
        if groups.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Button { model.selectFilter(nil) } label: { Chip(title: "All", isSelected: model.addonFilter == nil) }
                        .buttonStyle(.plain)
                    ForEach(groups) { group in
                        Button { model.selectFilter(group.id) } label: {
                            Chip(title: "\(group.addon.manifest.name) (\(group.streams.count))", isSelected: model.addonFilter == group.id)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
        }
    }

    private func play(_ stream: Stream, addon: AddonDescriptor) {
        guard let meta = model.meta else { return }
        let videoId = model.selectedVideoId ?? meta.id
        app.play(PlaybackRequest(stream: stream, meta: meta, videoId: videoId,
                                 addonTransportUrl: addon.transportUrl.hasPrefix("embedded://") ? nil : addon.transportUrl))
    }

    @ViewBuilder
    private func contextMenu(_ stream: Stream) -> some View {
        switch stream.source {
        case .url(let url):
            Button("Copy Stream URL") { copy(url.absoluteString) }
            Button("Open in Default App") { NSWorkspace.shared.open(url) }
        case .torrent:
            if let magnet = stream.magnetURL {
                Button("Copy Magnet Link") { copy(magnet.absoluteString) }
            }
        case .youTube(let id):
            Button("Open on YouTube") { NSWorkspace.shared.open(URL(string: "https://www.youtube.com/watch?v=\(id)")!) }
        case .external(let url), .playerFrame(let url):
            Button("Open in Browser") { NSWorkspace.shared.open(url) }
        case .unsupported:
            EmptyView()
        }
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

private struct StreamRow: View {
    var stream: Stream
    var addonName: String
    var action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                Text(stream.displayName.isEmpty ? addonName : stream.displayName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.foreground)
                    .multilineTextAlignment(.leading)
                    .frame(width: 96, alignment: .leading)
                    .lineLimit(4)

                // Long release names are truncated; seeders, size and source always stay visible.
                let parts = stream.descriptionParts
                VStack(alignment: .leading, spacing: 3) {
                    if !parts.title.isEmpty {
                        Text(parts.title)
                            .lineLimit(parts.stats == nil ? 5 : 3)
                    }
                    if let stats = parts.stats {
                        Text(stats)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                    if let extra = parts.extra {
                        Text(extra)
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryForeground)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: stream.isPlayableInApp ? "play.fill" : "arrow.up.right.square")
                    .font(.system(size: 14))
                    .foregroundStyle(isHovered ? Theme.foreground : Theme.tertiaryForeground)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(isHovered ? 0.12 : 0.05))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
