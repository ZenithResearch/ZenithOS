import Foundation
import Security

// MARK: - Models

struct MatrixRoom: Identifiable, Equatable, Hashable {
    let id: String          // e.g. "!abc:localhost"
    let displayName: String
}

enum MatrixError: LocalizedError {
    case badURL
    case httpError(Int, String)
    case notLoggedIn

    var errorDescription: String? {
        switch self {
        case .badURL:               return "Invalid homeserver URL"
        case .httpError(let c, let m): return "HTTP \(c): \(m)"
        case .notLoggedIn:          return "Not logged in"
        }
    }
}

// MARK: - MatrixClient

final class MatrixClient {
    let baseURL: String
    private let keyPrefix: String   // namespaces Keychain + UserDefaults keys

    private(set) var userId: String?
    private(set) var deviceId: String?

    // When set, all client API requests append ?user_id=<impersonateUserId>.
    // Used by app service clients that hold an as_token rather than a user session.
    var impersonateUserId: String?

    // Cached in memory — Keychain is read once at init and written only on
    // login/logout. This prevents macOS from showing a Keychain permission
    // dialog on every SwiftUI render cycle (which reads isLoggedIn).
    private var _accessToken: String?

    var accessToken: String? {
        get { _accessToken }
        set {
            _accessToken = newValue
            if let v = newValue { KeychainHelper.set(v, key: "\(keyPrefix)access_token") }
            else { KeychainHelper.delete("\(keyPrefix)access_token") }
        }
    }

    var isLoggedIn: Bool { _accessToken != nil }

    init(baseURL: String = MatrixHomeserverConfiguration.productionURL, keyPrefix: String = "matrix_") {
        self.baseURL   = MatrixHomeserverConfiguration.normalized(baseURL)
        self.keyPrefix = keyPrefix
        self._accessToken = KeychainHelper.get("\(keyPrefix)access_token")  // single read
        self.userId    = UserDefaults.standard.string(forKey: "\(keyPrefix)user_id")
        self.deviceId  = UserDefaults.standard.string(forKey: "\(keyPrefix)device_id")
    }

    // MARK: Register

    /// Matrix registration uses UIAA (interactive auth):
    /// 1. POST /register → 401 with session token + available flows
    /// 2. POST /register again with auth object to complete a flow
    ///
    /// Requires MATRIX_ENABLE_REGISTRATION=true in homeserver config.
    /// If registration is disabled the server returns M_FORBIDDEN.
    func register(username: String, password: String) async throws {
        let url = try endpoint("/_matrix/client/v3/register?kind=user")

        // Step 1 — get UIAA session
        var req1 = URLRequest(url: url)
        req1.httpMethod = "POST"
        req1.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req1.httpBody = try JSONSerialization.data(withJSONObject: [
            "username": username,
            "password": password,
        ])

        let (data1, resp1) = try await URLSession.shared.data(for: req1)
        let json1 = (try? JSONSerialization.jsonObject(with: data1) as? [String: Any]) ?? [:]

        // M_FORBIDDEN = registration disabled
        if let errcode = json1["errcode"] as? String, errcode == "M_FORBIDDEN" {
            let msg = json1["error"] as? String ?? "Registration is disabled on this homeserver."
            throw MatrixError.httpError(
                403,
                MatrixHomeserverConfiguration.registrationDisabledMessage(
                    for: baseURL,
                    serverMessage: msg
                )
            )
        }

        // If we got 200 directly (no flows required), we're done
        if (resp1 as? HTTPURLResponse)?.statusCode == 200,
           let token = json1["access_token"] as? String,
           let uid   = json1["user_id"]      as? String {
            accessToken = token
            userId      = uid
            deviceId    = json1["device_id"] as? String
            UserDefaults.standard.set(uid,      forKey: "\(keyPrefix)user_id")
            UserDefaults.standard.set(deviceId, forKey: "\(keyPrefix)device_id")
            return
        }

        // 401 = UIAA challenge — pick the simplest available flow
        guard let session = json1["session"] as? String else {
            throw MatrixError.httpError(0, "Unexpected registration response")
        }

        // Step 2 — complete with m.login.dummy (open registration) or m.login.recaptcha etc.
        // We attempt dummy first; if the server requires something else it will error clearly.
        var req2 = URLRequest(url: url)
        req2.httpMethod = "POST"
        req2.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req2.httpBody = try JSONSerialization.data(withJSONObject: [
            "username": username,
            "password": password,
            "auth": [
                "type":    "m.login.dummy",
                "session": session,
            ],
            "initial_device_display_name": "ZenithOS",
        ])

        let json2 = try await perform(req2)
        guard let token = json2["access_token"] as? String,
              let uid   = json2["user_id"]      as? String else {
            throw MatrixError.httpError(0, "Registration succeeded but no access_token returned")
        }
        accessToken = token
        userId      = uid
        deviceId    = json2["device_id"] as? String
        UserDefaults.standard.set(uid,      forKey: "\(keyPrefix)user_id")
        UserDefaults.standard.set(deviceId, forKey: "\(keyPrefix)device_id")
    }

    // MARK: Login

    func login(user: String, password: String) async throws {
        let url = try endpoint("/_matrix/client/v3/login")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "type": "m.login.password",
            "user": user,
            "password": password,
            "initial_device_display_name": "ZenithOS"
        ])
        let json = try await perform(req)
        guard let token = json["access_token"] as? String,
              let uid   = json["user_id"]      as? String else {
            throw MatrixError.httpError(0, "Missing access_token in response")
        }
        accessToken = token
        userId      = uid
        deviceId    = json["device_id"] as? String
        UserDefaults.standard.set(uid,      forKey: "\(keyPrefix)user_id")
        UserDefaults.standard.set(deviceId, forKey: "\(keyPrefix)device_id")
    }

    // MARK: Logout

    func logout() async {
        if let token = accessToken, let url = try? endpoint("/_matrix/client/v3/logout") {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = try? JSONSerialization.data(withJSONObject: [:])
            _ = try? await URLSession.shared.data(for: req)
        }
        accessToken = nil
        userId      = nil
        deviceId    = nil
        UserDefaults.standard.removeObject(forKey: "\(keyPrefix)user_id")
        UserDefaults.standard.removeObject(forKey: "\(keyPrefix)device_id")
    }

    // MARK: Rooms

    func joinedRooms() async throws -> [MatrixRoom] {
        guard let token = accessToken else { throw MatrixError.notLoggedIn }
        let url = try endpoint("/_matrix/client/v3/joined_rooms")
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let json = try await perform(req)
        guard let ids = json["joined_rooms"] as? [String] else { return [] }

        // Fetch display names concurrently
        return await withTaskGroup(of: MatrixRoom.self) { group in
            for roomId in ids {
                group.addTask { [weak self] in
                    let name = (try? await self?.roomName(roomId: roomId, token: token)) ?? roomId
                    return MatrixRoom(id: roomId, displayName: name)
                }
            }
            var rooms: [MatrixRoom] = []
            for await room in group { rooms.append(room) }
            return rooms.sorted { $0.displayName < $1.displayName }
        }
    }

    // MARK: Direct messages

    /// Returns an existing DM room with `userId` or creates a new one.
    /// Checks `m.direct` account data first to avoid duplicate DM rooms.
    func findOrCreateDM(userId: String) async throws -> MatrixRoom {
        guard let token = accessToken else { throw MatrixError.notLoggedIn }

        // Check account data for existing DM rooms with this user
        if let existing = try? await dmRoom(userId: userId, token: token) {
            return existing
        }

        // Create a new direct message room
        let url = try endpoint("/_matrix/client/v3/createRoom")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "preset":    "trusted_private_chat",
            "is_direct": true,
            "invite":    [userId],
        ])
        let json = try await perform(req)
        guard let roomId = json["room_id"] as? String else {
            throw MatrixError.httpError(0, "No room_id in createRoom response")
        }
        let name = (try? await roomName(roomId: roomId, token: token)) ?? userId
        return MatrixRoom(id: roomId, displayName: name)
    }

    private func dmRoom(userId: String, token: String) async throws -> MatrixRoom? {
        let myId = self.userId ?? ""
        let myEncoded = myId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? myId
        let url = try endpoint("/_matrix/client/v3/user/\(myEncoded)/account_data/m.direct")
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let json = try await perform(req)
        guard let roomIds = json[userId] as? [String], let roomId = roomIds.first else { return nil }
        let name = (try? await roomName(roomId: roomId, token: token)) ?? userId
        return MatrixRoom(id: roomId, displayName: name)
    }

    // MARK: Create room

    /// Creates a new Matrix room and returns the room ID.
    func createRoom(name: String, topic: String = "") async throws -> String {
        guard let token = accessToken else { throw MatrixError.notLoggedIn }
        let url = try endpoint("/_matrix/client/v3/createRoom")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var body: [String: Any] = ["name": name, "preset": "private_chat"]
        if !topic.isEmpty { body["topic"] = topic }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let json = try await perform(req)
        guard let roomId = json["room_id"] as? String else {
            throw MatrixError.httpError(0, "No room_id in createRoom response")
        }
        return roomId
    }

    // MARK: Private helpers

    private func roomName(roomId: String, token: String) async throws -> String? {
        let encoded = roomId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? roomId
        let url = try endpoint("/_matrix/client/v3/rooms/\(encoded)/state/m.room.name")
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let json = try await perform(req)
        return json["name"] as? String
    }

    /// Sets credentials directly without going through the login flow.
    /// Used by app service clients that authenticate via a shared AS token
    /// rather than a user password. Persists to Keychain/UserDefaults.
    func setAsCredentials(token: String, userId: String) {
        accessToken = token
        self.userId = userId
        impersonateUserId = userId
        UserDefaults.standard.set(userId, forKey: "\(keyPrefix)user_id")
    }

    func endpoint(_ path: String) throws -> URL {
        var urlString = "\(baseURL)\(path)"
        if let uid = impersonateUserId,
           let encoded = uid.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            let sep = path.contains("?") ? "&" : "?"
            urlString += "\(sep)user_id=\(encoded)"
        }
        guard let url = URL(string: urlString) else { throw MatrixError.badURL }
        return url
    }

    @discardableResult
    func perform(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? ""
            throw MatrixError.httpError(http.statusCode, body)
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

// MARK: - Keychain helper

private enum KeychainHelper {
    static func set(_ value: String, key: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String:   data,
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrAccount as String:      key,
            kSecReturnData as String:       true,
            kSecMatchLimit as String:       kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
