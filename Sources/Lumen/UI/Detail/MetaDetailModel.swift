import Foundation
import Observation

struct AddonStreams: Identifiable {
    var addon: AddonDescriptor
    var streams: [Stream] = []
    var isLoading = true
    var error: String?
    var id: String { addon.transportUrl }
}

@MainActor
@Observable
final class MetaDetailModel {
    let type: String
    let id: String
    var meta: MetaItem?
    var isLoadingMeta = true
    var metaError: String?
    var selectedSeason: Int?
    /// Video whose streams are listed (series episode, or the movie itself).
    var selectedVideoId: String?
    var streamGroups: [AddonStreams] = []
    var addonFilter: String?
    var recommendations: [MetaItem] = []
    /// Shown next to the row title ("Popular in <genre>" for the genre fallback, none for TMDB).
    var recommendationsSource: String?
    var isLoadingRecommendations = false
    /// Addon whose streams are pre-selected (e.g. Torrentio RD) until the user picks a filter.
    private var preferredAddonId: String?
    private var userPickedFilter = false
    private var streamTasks: [Task<Void, Never>] = []
    private var loadedStreamsFor: String?

    init(type: String, id: String, preview: MetaItem?) {
        self.type = type
        self.id = id
        meta = preview
    }

    func load(profile: ProfileStore, library: LibraryStore) async {
        guard isLoadingMeta else { return }
        let addons = profile.addons(supporting: "meta", type: type, id: id)
        var lastError: Error?
        for addon in addons {
            do {
                let meta = try await AddonClient.shared.meta(addon: addon, type: type, id: id)
                self.meta = meta
                lastError = nil
                break
            } catch {
                lastError = error
            }
        }
        isLoadingMeta = false
        if let lastError, meta == nil || meta?.description == nil && meta?.videos.isEmpty == true {
            metaError = addons.isEmpty ? "No installed addon provides details for this item." : lastError.localizedDescription
        }
        guard let meta else { return }

        if meta.videos.isEmpty {
            selectVideo(meta.behaviorHints.defaultVideoId ?? meta.id, profile: profile)
        } else {
            // Start on the season of the episode the user is watching, else the first season.
            let item = library.item(meta.id)
            let current = item?.state.videoId.flatMap { vid in meta.videos.first { $0.id == vid } }
            selectedSeason = current?.season ?? meta.seasons.first
            if meta.videos.count == 1, let only = meta.videos.first {
                selectVideo(only.id, profile: profile)
            }
        }
        await loadRecommendations(for: meta, addons: profile.activeAddons)
    }

    private func loadRecommendations(for meta: MetaItem, addons: [AddonDescriptor]) async {
        isLoadingRecommendations = true
        let result = await Recommendations.load(for: meta, addons: addons)
        recommendations = result?.items ?? []
        recommendationsSource = result?.source
        isLoadingRecommendations = false
    }

    var isSeries: Bool { !(meta?.videos.isEmpty ?? true) }

    var selectedVideo: Video? {
        guard let selectedVideoId else { return nil }
        return meta?.videos.first { $0.id == selectedVideoId }
    }

    func selectVideo(_ videoId: String?, profile: ProfileStore) {
        selectedVideoId = videoId
        guard let videoId else {
            streamTasks.forEach { $0.cancel() }
            loadedStreamsFor = nil
            return
        }
        loadStreams(videoId: videoId, profile: profile)
    }

    func reloadStreams(profile: ProfileStore) {
        loadedStreamsFor = nil
        if let selectedVideoId { loadStreams(videoId: selectedVideoId, profile: profile) }
    }

    private func loadStreams(videoId: String, profile: ProfileStore) {
        guard loadedStreamsFor != videoId else { return }
        loadedStreamsFor = videoId
        addonFilter = nil
        userPickedFilter = false
        let type = self.type
        let addons = profile.addons(supporting: "stream", type: type, id: videoId)
        // Streams embedded in the meta object (e.g. YouTube channels) come first.
        var groups: [AddonStreams] = []
        if let embedded = meta?.videos.first(where: { $0.id == videoId })?.streams, !embedded.isEmpty {
            let pseudo = AddonDescriptor(manifest: placeholderManifest(name: meta?.name ?? "Item"), transportUrl: "embedded://\(videoId)")
            groups.append(AddonStreams(addon: pseudo, streams: embedded, isLoading: false))
        }
        let preferred = StreamAddonPreference.preferred(among: addons, setting: profile.settings.preferredStreamAddon)
        preferredAddonId = preferred?.transportUrl
        // The preferred addon's streams are listed first, also under "All".
        let ordered = addons.filter { $0.transportUrl == preferredAddonId } + addons.filter { $0.transportUrl != preferredAddonId }
        groups += ordered.map { AddonStreams(addon: $0) }
        streamGroups = groups
        // One independent request per addon; each group fills in as its addon responds.
        streamTasks.forEach { $0.cancel() }
        streamTasks = addons.map { addon in
            Task { [weak self] in
                let result: Result<[Stream], Error>
                do {
                    result = .success(try await AddonClient.shared.streams(addon: addon, type: type, id: videoId))
                } catch {
                    result = .failure(error)
                }
                guard let self, !Task.isCancelled, self.loadedStreamsFor == videoId,
                      let index = self.streamGroups.firstIndex(where: { $0.id == addon.transportUrl }) else { return }
                self.streamGroups[index].isLoading = false
                switch result {
                case .success(let streams): self.streamGroups[index].streams = streams
                case .failure(let error): self.streamGroups[index].error = error.localizedDescription
                }
                self.applyPreferredFilter()
            }
        }
    }

    /// User-initiated filter change; stops the automatic preference from overriding it.
    func selectFilter(_ addonId: String?) {
        userPickedFilter = true
        addonFilter = addonId
    }

    private func applyPreferredFilter() {
        guard !userPickedFilter, let preferredAddonId,
              streamGroups.contains(where: { $0.id == preferredAddonId && !$0.streams.isEmpty }) else { return }
        addonFilter = preferredAddonId
    }

    private func placeholderManifest(name: String) -> Manifest {
        let json = #"{"id":"embedded","version":"1.0.0","name":"\#(name.replacingOccurrences(of: "\"", with: "'"))","resources":[],"types":[]}"#
        return try! JSON.decoder.decode(Manifest.self, from: Data(json.utf8))
    }

    var isLoadingStreams: Bool { streamGroups.contains(where: \.isLoading) }

    var visibleGroups: [AddonStreams] {
        let groups = streamGroups.filter { !$0.streams.isEmpty }
        guard let addonFilter else { return groups }
        return groups.filter { $0.id == addonFilter }
    }
}
