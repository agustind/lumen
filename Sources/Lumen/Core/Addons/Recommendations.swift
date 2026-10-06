import Foundation

/// "You might also like" for a detail page: TMDB recommendations when a TMDB token is configured,
/// otherwise popular titles in the item's genre from an addon catalog (Cinemeta's "Popular" by default).
enum Recommendations {
    struct Result: Sendable {
        var items: [MetaItem]
        /// Shown next to the row title: none for TMDB, "Popular in <genre>" for the fallback.
        var source: String?
    }

    static func load(for meta: MetaItem, addons: [AddonDescriptor]) async -> Result? {
        if TMDBClient.isConfigured {
            do {
                let items = try await TMDBClient.shared.recommendations(for: meta)
                if !items.isEmpty { return Result(items: items, source: nil) }
            } catch {
                Log.error("TMDB recommendations failed for \(meta.id): \(error)")
            }
        }
        return await sameGenre(as: meta, addons: addons)
    }

    /// Popular titles from the first of the item's genres that an installed catalog can filter by.
    static func sameGenre(as meta: MetaItem, addons: [AddonDescriptor], limit: Int = 20) async -> Result? {
        for genre in meta.allGenres.prefix(3) {
            guard let (addon, catalog) = genreCatalog(type: meta.type, genre: genre, addons: addons),
                  let items = try? await AddonClient.shared.catalog(addon: addon, catalog: catalog, extra: [("genre", genre)])
            else { continue }
            let others = items.filter { $0.id != meta.id }.prefix(limit)
            if !others.isEmpty { return Result(items: Array(others), source: "Popular in \(genre)") }
        }
        return nil
    }

    /// A catalog of `type` that lists `genre` among its genre options, preferring Cinemeta-style "top".
    static func genreCatalog(type: String, genre: String, addons: [AddonDescriptor]) -> (AddonDescriptor, ManifestCatalog)? {
        let candidates = addons.flatMap { addon in addon.manifest.catalogs.map { (addon, $0) } }.filter { _, catalog in
            catalog.type == type
                && catalog.extra(named: "genre")?.options?.contains(genre) == true
                && catalog.requiredExtras.allSatisfy { $0.name == "genre" }
        }
        return candidates.first { $0.1.id == "top" } ?? candidates.first
    }
}
