import Foundation
import Observation

/// Account, installed addons and settings. Persists locally and syncs addons with the Stremio API.
@MainActor
@Observable
final class ProfileStore {
    struct Auth: Codable, Hashable {
        var key: String
        var user: User
    }

    private struct Persisted: Codable {
        var auth: Auth?
        var addons: [AddonDescriptor]
        var settings: AppSettings
    }

    private(set) var auth: Auth?
    private(set) var addons: [AddonDescriptor]
    var settings: AppSettings {
        didSet { if settings != oldValue { persist() } }
    }
    private(set) var isSyncing = false
    var lastError: String?

    private let api = StremioAPI()
    private static let fileName = "profile.json"

    var isLoggedIn: Bool { auth != nil }

    init() {
        if let persisted = Storage.load(Persisted.self, from: Self.fileName) {
            auth = persisted.auth
            addons = persisted.addons.isEmpty ? Self.officialAddons : persisted.addons
            settings = persisted.settings
        } else {
            auth = nil
            addons = Self.officialAddons
            settings = AppSettings()
        }
    }

    nonisolated static let officialAddons: [AddonDescriptor] = {
        guard let url = Bundle.module.url(forResource: "official-addons", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let addons = try? JSON.decoder.decode([AddonDescriptor].self, from: data) else { return [] }
        return addons
    }()

    private func persist() {
        Storage.save(Persisted(auth: auth, addons: addons, settings: settings), to: Self.fileName)
    }

    /// Addons usable by the app (supported protocol; adult ones hidden unless enabled).
    var activeAddons: [AddonDescriptor] {
        addons.filter { !$0.isLegacy && (settings.showAdultAddons || !$0.manifest.behaviorHints.adult) }
    }

    func addons(supporting resource: String, type: String, id: String?) -> [AddonDescriptor] {
        activeAddons.filter { $0.supports(resource: resource, type: type, id: id) }
    }

    func isInstalled(_ addon: AddonDescriptor) -> Bool {
        addons.contains { $0.transportUrl == addon.transportUrl || $0.manifest.id == addon.manifest.id }
    }

    // MARK: Account

    func login(email: String, password: String) async throws {
        let response = try await api.login(email: email, password: password)
        auth = Auth(key: response.authKey, user: response.user)
        persist()
        await pullAddons()
    }

    func register(email: String, password: String, marketing: Bool) async throws {
        let response = try await api.register(email: email, password: password, marketing: marketing)
        auth = Auth(key: response.authKey, user: response.user)
        // A new account starts with the addons installed while logged out.
        persist()
        await pushAddons()
    }

    func logout() async {
        if let key = auth?.key { try? await api.logout(authKey: key) }
        auth = nil
        addons = Self.officialAddons
        persist()
    }

    // MARK: Addon collection

    func pullAddons() async {
        guard let key = auth?.key else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let remote = try await api.addonCollectionGet(authKey: key)
            if !remote.isEmpty {
                addons = remote
                persist()
            }
            lastError = nil
        } catch {
            Log.error("addonCollectionGet failed: \(error)")
            if (error as? APIError)?.code == 1 { await handleInvalidSession() }
            lastError = error.localizedDescription
        }
    }

    private func pushAddons() async {
        guard let key = auth?.key else { return }
        do {
            try await api.addonCollectionSet(authKey: key, addons: addons)
        } catch {
            Log.error("addonCollectionSet failed: \(error)")
            lastError = error.localizedDescription
        }
    }

    private func handleInvalidSession() async {
        auth = nil
        persist()
    }

    func install(_ addon: AddonDescriptor) async {
        var addon = addon
        if let index = addons.firstIndex(where: { $0.manifest.id == addon.manifest.id }) {
            // Upgrading/reconfiguring keeps the existing position and flags.
            addon.flags = addons[index].flags
            addons[index] = addon
        } else {
            addons.append(addon)
        }
        persist()
        await pushAddons()
    }

    func uninstall(_ addon: AddonDescriptor) async {
        guard !addon.flags.protected else { return }
        addons.removeAll { $0.transportUrl == addon.transportUrl }
        persist()
        await pushAddons()
    }

    func moveAddons(fromOffsets source: IndexSet, toOffset destination: Int) async {
        addons.move(fromOffsets: source, toOffset: destination)
        persist()
        await pushAddons()
    }

    /// Re-fetches every manifest so catalogs and resources stay current. Only used when logged out;
    /// logged-in users get refreshed manifests from `addonCollectionGet(update: true)`.
    func refreshManifests() async {
        var updated = addons
        let indexed = Array(addons.enumerated()).filter { !$0.element.isLegacy }
        await forEachConcurrently(indexed) { entry in
            try? await AddonClient.shared.fetchManifest(transportUrl: entry.element.transportUrl)
        } onResult: { entry, fresh in
            if let fresh, fresh.manifest != updated[entry.offset].manifest {
                updated[entry.offset].manifest = fresh.manifest
            }
        }
        if updated != addons {
            addons = updated
            persist()
        }
    }
}
