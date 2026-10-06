import Foundation

struct User: Codable, Hashable, Sendable {
    var id: String
    var email: String
    var avatar: URL?

    private enum CodingKeys: String, CodingKey { case id = "_id", email, avatar }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lossy(String.self, .id) ?? ""
        email = c.lossy(String.self, .email) ?? ""
        avatar = c.lossyURL(.avatar)
    }
}

struct APIError: LocalizedError, Decodable {
    var message: String
    var code: Int

    var errorDescription: String? { message }
}

/// Client for `https://api.strem.io/api/*` (accounts, addon collection, library datastore).
struct StremioAPI: Sendable {
    var baseURL = URL(string: "https://api.strem.io/api/")!
    var session: URLSession = .shared

    struct AuthResponse: Decodable {
        var authKey: String
        var user: User
    }

    struct CollectionResponse: Decodable {
        var addons: [AddonDescriptor]

        private enum CodingKeys: String, CodingKey { case addons }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            addons = c.lossyArray(AddonDescriptor.self, .addons)
        }
    }

    private struct Envelope<T: Decodable>: Decodable {
        var result: T?
        var error: APIError?
    }

    private struct Empty: Decodable {}

    func call<T: Decodable>(_ method: String, _ body: [String: Any], as type: T.Type = T.self) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(method))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30
        let (data, _) = try await session.data(for: request)
        let envelope = try JSON.decoder.decode(Envelope<T>.self, from: data)
        if let error = envelope.error { throw error }
        guard let result = envelope.result else { throw APIError(message: "Empty response from Stremio API", code: -1) }
        return result
    }

    func login(email: String, password: String) async throws -> AuthResponse {
        try await call("login", ["type": "Login", "email": email, "password": password, "facebook": false])
    }

    func register(email: String, password: String, marketing: Bool) async throws -> AuthResponse {
        try await call("register", [
            "type": "Register", "email": email, "password": password,
            "gdpr_consent": ["tos": true, "privacy": true, "marketing": marketing, "from": "macos"],
        ])
    }

    func logout(authKey: String) async throws {
        let _: JSONValue = try await call("logout", ["type": "Logout", "authKey": authKey])
    }

    func getUser(authKey: String) async throws -> User {
        try await call("getUser", ["type": "GetUser", "authKey": authKey])
    }

    func addonCollectionGet(authKey: String) async throws -> [AddonDescriptor] {
        let response: CollectionResponse = try await call("addonCollectionGet", [
            "type": "AddonCollectionGet", "authKey": authKey, "update": true,
        ])
        return response.addons
    }

    func addonCollectionSet(authKey: String, addons: [AddonDescriptor]) async throws {
        let encoded = try JSONSerialization.jsonObject(with: JSON.encoder.encode(addons))
        let _: JSONValue = try await call("addonCollectionSet", [
            "type": "AddonCollectionSet", "authKey": authKey, "addons": encoded,
        ])
    }

    /// Returns `[id: mtime]` for every library item stored remotely.
    func datastoreMeta(authKey: String) async throws -> [String: Date] {
        let result: [JSONValue] = try await call("datastoreMeta", ["authKey": authKey, "collection": "libraryItem"])
        var meta: [String: Date] = [:]
        for entry in result {
            guard case .array(let pair) = entry, pair.count == 2,
                  let id = pair[0].stringValue, let millis = pair[1].doubleValue else { continue }
            meta[id] = Date(timeIntervalSince1970: millis / 1000)
        }
        return meta
    }

    func datastoreGet(authKey: String, ids: [String], all: Bool = false) async throws -> [LibraryItem] {
        let items: LossyArray<LibraryItem> = try await call("datastoreGet", [
            "authKey": authKey, "collection": "libraryItem", "ids": ids, "all": all,
        ])
        return items.elements
    }

    func datastorePut(authKey: String, changes: [LibraryItem]) async throws {
        guard !changes.isEmpty else { return }
        let encoded = try JSONSerialization.jsonObject(with: JSON.encoder.encode(changes))
        let _: JSONValue = try await call("datastorePut", [
            "authKey": authKey, "collection": "libraryItem", "changes": encoded,
        ])
    }
}
