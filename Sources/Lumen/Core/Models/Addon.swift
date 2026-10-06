import Foundation

/// An installed (or installable) addon: its manifest plus where to reach it.
struct AddonDescriptor: Codable, Hashable, Identifiable, Sendable {
    var manifest: Manifest
    var transportUrl: String
    var flags: Flags

    struct Flags: Codable, Hashable, Sendable {
        var official: Bool = false
        var protected: Bool = false

        init(official: Bool = false, protected: Bool = false) {
            self.official = official
            self.protected = protected
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            official = c.lossy(Bool.self, .official) ?? false
            protected = c.lossy(Bool.self, .protected) ?? false
        }
    }

    var id: String { transportUrl }

    init(manifest: Manifest, transportUrl: String, flags: Flags = Flags()) {
        self.manifest = manifest
        self.transportUrl = transportUrl
        self.flags = flags
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        manifest = try c.decode(Manifest.self, forKey: .manifest)
        transportUrl = try c.decode(String.self, forKey: .transportUrl)
        flags = c.lossy(Flags.self, .flags) ?? Flags()
    }

    /// The addon's base URL (transport URL without `/manifest.json`).
    var baseURL: URL? {
        var string = transportUrl
        if string.hasPrefix("stremio://") { string = "https://" + string.dropFirst("stremio://".count) }
        if string.hasSuffix("/manifest.json") { string.removeLast("/manifest.json".count) }
        while string.hasSuffix("/") { string.removeLast() }
        return URL(string: string)
    }

    /// Legacy (v1 protocol) addons are not supported.
    var isLegacy: Bool { transportUrl.hasSuffix("/stremio/v1") || transportUrl.hasSuffix("/stremio/v1/") }

    var isConfigurable: Bool { manifest.behaviorHints.configurable }

    /// URL of the addon's configuration page, if it has one.
    var configureURL: URL? {
        guard isConfigurable, let base = baseURL else { return nil }
        return base.appendingPathComponent("configure")
    }

    func supports(resource: String, type: String, id: String?) -> Bool {
        manifest.supports(resource: resource, type: type, id: id)
    }
}

struct Manifest: Codable, Hashable, Sendable {
    var id: String
    var version: String
    var name: String
    var description: String?
    var logo: URL?
    var background: URL?
    var types: [String]
    var resources: [ManifestResource]
    var idPrefixes: [String]?
    var catalogs: [ManifestCatalog]
    var addonCatalogs: [ManifestCatalog]
    var behaviorHints: BehaviorHints
    /// The full manifest as received, re-emitted verbatim when syncing to the API.
    var raw: JSONValue

    struct BehaviorHints: Hashable, Sendable {
        var adult = false
        var p2p = false
        var configurable = false
        var configurationRequired = false
    }

    private enum CodingKeys: String, CodingKey {
        case id, version, name, description, logo, background, types, resources, idPrefixes
        case catalogs, addonCatalogs, behaviorHints
    }

    private enum HintKeys: String, CodingKey {
        case adult, p2p, configurable, configurationRequired
    }

    init(from decoder: Decoder) throws {
        raw = try JSONValue(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        version = c.lossyString(.version) ?? "0.0.0"
        name = c.lossy(String.self, .name) ?? id
        description = c.lossy(String.self, .description)
        logo = c.lossyURL(.logo)
        background = c.lossyURL(.background)
        types = c.lossyArray(String.self, .types)
        resources = c.lossyArray(ManifestResource.self, .resources)
        idPrefixes = c.lossy([String].self, .idPrefixes)
        catalogs = c.lossyArray(ManifestCatalog.self, .catalogs)
        addonCatalogs = c.lossyArray(ManifestCatalog.self, .addonCatalogs)
        var hints = BehaviorHints()
        if let h = try? c.nestedContainer(keyedBy: HintKeys.self, forKey: .behaviorHints) {
            hints.adult = h.lossy(Bool.self, .adult) ?? false
            hints.p2p = h.lossy(Bool.self, .p2p) ?? false
            hints.configurable = h.lossy(Bool.self, .configurable) ?? false
            hints.configurationRequired = h.lossy(Bool.self, .configurationRequired) ?? false
        }
        behaviorHints = hints
    }

    func encode(to encoder: Encoder) throws {
        try raw.encode(to: encoder)
    }

    static func == (lhs: Manifest, rhs: Manifest) -> Bool { lhs.raw == rhs.raw }
    func hash(into hasher: inout Hasher) { hasher.combine(raw) }

    func supports(resource name: String, type: String, id: String?) -> Bool {
        guard let resource = resources.first(where: { $0.name == name }) else { return false }
        let types = resource.types ?? self.types
        guard types.contains(type) else { return false }
        guard let id else { return true }
        guard let prefixes = resource.idPrefixes ?? idPrefixes, !prefixes.isEmpty else { return true }
        return prefixes.contains { id.hasPrefix($0) }
    }

    var resourceNames: [String] { resources.map(\.name) }
}

struct ManifestResource: Codable, Hashable, Sendable {
    var name: String
    var types: [String]?
    var idPrefixes: [String]?

    private enum CodingKeys: String, CodingKey { case name, types, idPrefixes }

    init(from decoder: Decoder) throws {
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            self.name = name
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        types = c.lossy([String].self, .types)
        idPrefixes = c.lossy([String].self, .idPrefixes)
    }
}

struct ManifestCatalog: Codable, Hashable, Identifiable, Sendable {
    var type: String
    var id: String
    var name: String?
    var extra: [ExtraProp]

    var stableId: String { "\(type)/\(id)" }

    private enum CodingKeys: String, CodingKey {
        case type, id, name, extra, extraSupported, extraRequired, genres
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        id = try c.decode(String.self, forKey: .id)
        name = c.lossy(String.self, .name)
        if let extra = c.lossy(LossyArray<ExtraProp>.self, .extra)?.elements {
            self.extra = extra
        } else {
            // Legacy manifests describe extras with `extraSupported`/`extraRequired`/`genres`.
            let supported = c.lossy([String].self, .extraSupported) ?? []
            let required = Set(c.lossy([String].self, .extraRequired) ?? [])
            let genres = c.lossy([String].self, .genres)
            extra = supported.map { name in
                ExtraProp(name: name, isRequired: required.contains(name),
                          options: name == "genre" ? genres : nil, optionsLimit: 1)
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(extra, forKey: .extra)
    }

    func extra(named name: String) -> ExtraProp? { extra.first { $0.name == name } }

    var requiredExtras: [ExtraProp] { extra.filter(\.isRequired) }

    /// Catalogs shown on the board: those with no required extras.
    var isBoardCatalog: Bool { requiredExtras.isEmpty }

    var supportsSearch: Bool { extra(named: "search") != nil }

    /// Search-only catalogs: `search` is the only required extra.
    var isSearchCatalog: Bool {
        supportsSearch && requiredExtras.allSatisfy { $0.name == "search" }
    }
}

struct ExtraProp: Codable, Hashable, Sendable {
    var name: String
    var isRequired: Bool
    var options: [String]?
    var optionsLimit: Int

    init(name: String, isRequired: Bool = false, options: [String]? = nil, optionsLimit: Int = 1) {
        self.name = name
        self.isRequired = isRequired
        self.options = options
        self.optionsLimit = optionsLimit
    }

    private enum CodingKeys: String, CodingKey { case name, isRequired, options, optionsLimit }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        isRequired = c.lossy(Bool.self, .isRequired) ?? false
        options = c.lossy(LossyArray<String>.self, .options)?.elements
        optionsLimit = c.lossyInt(.optionsLimit) ?? 1
    }
}
