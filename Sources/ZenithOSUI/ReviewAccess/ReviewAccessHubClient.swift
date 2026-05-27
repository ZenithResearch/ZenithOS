import Foundation
import Security

struct ReviewAccessPolicyPayload: Encodable {
    var deploymentID: String
    var deploymentSlug: String
    var allowedOrigin: String
    var subjectPattern: String

    enum CodingKeys: String, CodingKey {
        case deploymentID = "deployment_id"
        case deploymentSlug = "deployment_slug"
        case allowedOrigin = "allowed_origin"
        case subjectPattern = "subject_pattern"
    }
}

struct ReviewAccessRotateRequest: Encodable {
    var clientID: String
    var clientSlug: String
    var clientName: String
    var rolodexEntryPath: String?
    var projectID: String
    var projectSlug: String
    var projectName: String
    var deploymentID: String?
    var deploymentSlug: String?
    var allowedOrigin: String?
    var subjectPattern: String?
    var policies: [ReviewAccessPolicyPayload]
    var accessCodeID: String
    var accessLabel: String
    var mode: Mode
    var accessCode: String?
    var deploymentScopedAccess: Bool

    enum Mode: String, Encodable {
        case generate
        case provided
    }

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case clientSlug = "client_slug"
        case clientName = "client_name"
        case rolodexEntryPath = "rolodex_entry_path"
        case projectID = "project_id"
        case projectSlug = "project_slug"
        case projectName = "project_name"
        case deploymentID = "deployment_id"
        case deploymentSlug = "deployment_slug"
        case allowedOrigin = "allowed_origin"
        case subjectPattern = "subject_pattern"
        case policies
        case accessCodeID = "access_code_id"
        case accessLabel = "access_label"
        case mode
        case accessCode = "access_code"
        case deploymentScopedAccess = "deployment_scoped_access"
    }
}

struct ReviewAccessRotateResponse: Decodable {
    var clientID: String
    var projectID: String
    var deploymentID: String?
    var accessCodeID: String
    var accessLabel: String
    var rawCode: String?
    var rawCodePresent: Bool
    var projectScopedAccess: Bool
    var emailConfigured: Bool
    var policyCount: Int
    var active: Bool
    var lastRotatedAt: Date?
    var secretsPrinted: Bool

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case projectID = "project_id"
        case deploymentID = "deployment_id"
        case accessCodeID = "access_code_id"
        case accessLabel = "access_label"
        case rawCode = "raw_code"
        case rawCodePresent = "raw_code_present"
        case projectScopedAccess = "project_scoped_access"
        case emailConfigured = "email_configured"
        case policyCount = "policy_count"
        case active
        case lastRotatedAt = "last_rotated_at"
        case secretsPrinted = "secrets_printed"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clientID = try container.decode(String.self, forKey: .clientID)
        projectID = try container.decode(String.self, forKey: .projectID)
        deploymentID = try container.decodeIfPresent(String.self, forKey: .deploymentID)
        accessCodeID = try container.decode(String.self, forKey: .accessCodeID)
        accessLabel = try container.decode(String.self, forKey: .accessLabel)
        rawCode = try container.decodeIfPresent(String.self, forKey: .rawCode)
        rawCodePresent = try container.decodeIfPresent(Bool.self, forKey: .rawCodePresent) ?? (rawCode != nil)
        projectScopedAccess = try container.decodeIfPresent(Bool.self, forKey: .projectScopedAccess) ?? (deploymentID == nil)
        emailConfigured = try container.decodeIfPresent(Bool.self, forKey: .emailConfigured) ?? false
        policyCount = try container.decodeIfPresent(Int.self, forKey: .policyCount) ?? 0
        active = try container.decodeIfPresent(Bool.self, forKey: .active) ?? true
        lastRotatedAt = try container.decodeIfPresent(Date.self, forKey: .lastRotatedAt)
        secretsPrinted = try container.decodeIfPresent(Bool.self, forKey: .secretsPrinted) ?? false
    }
}

struct ReviewAccessCapabilitiesResponse: Decodable {
    var ok: Bool
    var hub: String
    var capabilities: [String]
    var secretsPrinted: Bool

    enum CodingKeys: String, CodingKey {
        case ok
        case hub
        case capabilities
        case secretsPrinted = "secrets_printed"
    }
}

struct ReviewAccessAdminTokenUpdateResponse: Decodable {
    var configured: Bool
    var capabilities: [String]
    var secretsPrinted: Bool

    enum CodingKeys: String, CodingKey {
        case configured
        case capabilities
        case secretsPrinted = "secrets_printed"
    }
}

enum ReviewAccessHubClientError: LocalizedError {
    case missingAdminToken
    case badURL
    case http(Int, String)
    case adminHTTP(Int, String, String)
    case rawCodeMissing
    case secretsPrinted
    case keychainWriteFailed(OSStatus)
    case keychainDeleteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingAdminToken:
            return "Missing Review Access admin token in Keychain. Expected service zenith-hub-review-access-admin-token."
        case .badURL:
            return "Invalid Hub API URL."
        case .http(let status, let body):
            if status == 404 {
                return "Hub returned HTTP 404: \(body). This Hub does not expose the Review Access admin endpoint yet; deploy/restart the Hub with the latest gateway before verifying or setting the token from ZenithOS."
            }
            return "Hub returned HTTP \(status): \(body)"
        case .adminHTTP(let status, let body, let path):
            return Self.adminHTTPDescription(status: status, body: body, path: path)
        case .rawCodeMissing:
            return "Hub did not return a generated raw code."
        case .secretsPrinted:
            return "Hub response indicated secrets_printed=true; refusing to continue."
        case .keychainWriteFailed(let status):
            return "Could not save Review Access admin token to Keychain (status \(status))."
        case .keychainDeleteFailed(let status):
            return "Could not delete Review Access admin token from Keychain (status \(status))."
        }
    }

    private static func adminHTTPDescription(status: Int, body: String, path: String) -> String {
        let prefix = "Hub returned HTTP \(status) for /\(path): \(body)."
        if path.hasPrefix("v1/admin/fs/") {
            if body.contains("outside_namespace") {
                return "\(prefix) HubFS rejected this path because it is outside the authenticated Gateway-owned filesystem volumes."
            }
            if body.contains("not_found") {
                return "\(prefix) HubFS is live, but the Gateway-owned backing volume does not contain this path. Service-level filesystems are separate volumes until explicitly attached to HubFS."
            }
            if body.contains("is_directory") {
                return "\(prefix) HubFS is live, but this path is a directory; use list or manifest instead of content."
            }
            return "\(prefix) This Hub does not expose the HubFS endpoint yet; deploy/restart Gateway with the HubFS routes before verifying direct Hub filesystem access from ZenithOS."
        }
        guard status == 404 else { return prefix }
        if path.hasPrefix("v1/admin/mirror/files/") {
            if body.contains("mirror backing file not found") {
                return "\(prefix) The Hub mirror endpoint exists, but the backing file is not present under the configured mirror roots."
            }
            return "\(prefix) This Hub does not expose the mirror file content endpoint yet; deploy/restart Gateway and Cases with the artifact mirror endpoints before previewing remote /data files from ZenithOS."
        }
        if path.hasPrefix("v1/admin/execution-artifacts/") || path.contains("/artifacts/") {
            return "\(prefix) This Hub does not expose the execution artifact content endpoint yet, or the requested registered artifact is not available on this Hub."
        }
        if path.hasPrefix("v1/admin/review-auth/") {
            return "\(prefix) This Hub does not expose the Review Access admin endpoint yet; deploy/restart the Hub with the latest gateway before verifying or setting the token from ZenithOS."
        }
        return prefix
    }
}

final class ReviewAccessHubClient {
    static let defaultHubURL = URL(string: "https://hub.zenith-research.ca")!
    static let keychainService = "zenith-hub-review-access-admin-token"
    static let keychainAccount = "review_access_admin"

    private let baseURL: URL
    private let session: URLSession

    private static func safeErrorBody(from data: Data) -> String {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return "redacted empty response"
        }
        let lowered = text.lowercased()
        let sensitiveMarkers = ["token", "secret", "password", "access_code", "authorization", "bearer", "raw_code"]
        guard !sensitiveMarkers.contains(where: { lowered.contains($0) }) else {
            return "redacted response body"
        }
        return String(text.prefix(300))
    }

    init(baseURL: URL = ReviewAccessHubClient.defaultHubURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func rotate(_ payload: ReviewAccessRotateRequest) async throws -> ReviewAccessRotateResponse {
        guard let token = Self.adminTokenFromKeychain(), !token.isEmpty else {
            throw ReviewAccessHubClientError.missingAdminToken
        }
        return try await rotate(payload, adminToken: token)
    }

    func verifyAdminToken(_ rawToken: String) async throws -> ReviewAccessCapabilitiesResponse {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw ReviewAccessHubClientError.missingAdminToken
        }
        let endpoint = baseURL.appendingPathComponent("v1/admin/review-auth/capabilities")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ReviewAccessHubClientError.http(0, "Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ReviewAccessHubClientError.http(http.statusCode, Self.safeErrorBody(from: data))
        }
        let decoded = try JSONDecoder.reviewAccessHub.decode(ReviewAccessCapabilitiesResponse.self, from: data)
        if decoded.secretsPrinted {
            throw ReviewAccessHubClientError.secretsPrinted
        }
        return decoded
    }

    func updateAdminTokenOnHub(newToken rawNewToken: String, currentToken rawCurrentToken: String?) async throws -> ReviewAccessAdminTokenUpdateResponse {
        let newToken = rawNewToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newToken.isEmpty else {
            throw ReviewAccessHubClientError.missingAdminToken
        }
        let endpoint = baseURL.appendingPathComponent("v1/admin/review-auth/admin-token")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let currentToken = rawCurrentToken?.trimmingCharacters(in: .whitespacesAndNewlines), !currentToken.isEmpty {
            request.setValue("Bearer \(currentToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder.reviewAccessHub.encode(["value": newToken])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ReviewAccessHubClientError.http(0, "Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ReviewAccessHubClientError.http(http.statusCode, Self.safeErrorBody(from: data))
        }
        let decoded = try JSONDecoder.reviewAccessHub.decode(ReviewAccessAdminTokenUpdateResponse.self, from: data)
        if decoded.secretsPrinted {
            throw ReviewAccessHubClientError.secretsPrinted
        }
        return decoded
    }

    func adminData(path: String, queryItems: [URLQueryItem] = []) async throws -> Data {
        guard let token = Self.adminTokenFromKeychain()?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw ReviewAccessHubClientError.missingAdminToken
        }

        var endpoint = baseURL
        for component in path.split(separator: "/") {
            endpoint.appendPathComponent(String(component))
        }
        if !queryItems.isEmpty {
            guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
                throw ReviewAccessHubClientError.badURL
            }
            components.queryItems = queryItems
            guard let url = components.url else {
                throw ReviewAccessHubClientError.badURL
            }
            endpoint = url
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ReviewAccessHubClientError.http(0, "Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ReviewAccessHubClientError.adminHTTP(http.statusCode, Self.safeErrorBody(from: data), path)
        }
        return data
    }

    func rotate(_ payload: ReviewAccessRotateRequest, adminToken rawToken: String) async throws -> ReviewAccessRotateResponse {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw ReviewAccessHubClientError.missingAdminToken
        }
        let endpoint = baseURL.appendingPathComponent("v1/admin/review-auth/access-codes/rotate")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder.reviewAccessHub.encode(payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ReviewAccessHubClientError.http(0, "Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ReviewAccessHubClientError.http(http.statusCode, Self.safeErrorBody(from: data))
        }
        let decoded = try JSONDecoder.reviewAccessHub.decode(ReviewAccessRotateResponse.self, from: data)
        if decoded.secretsPrinted {
            throw ReviewAccessHubClientError.secretsPrinted
        }
        return decoded
    }

    static func adminTokenFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func hasAdminTokenInKeychain() -> Bool {
        guard let token = adminTokenFromKeychain() else { return false }
        return !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func saveAdminTokenToKeychain(_ rawToken: String) throws {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            try deleteAdminTokenFromKeychain()
            return
        }

        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw ReviewAccessHubClientError.keychainWriteFailed(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw ReviewAccessHubClientError.keychainWriteFailed(addStatus)
        }
    }

    static func deleteAdminTokenFromKeychain() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ReviewAccessHubClientError.keychainDeleteFailed(status)
        }
    }
}

private extension JSONEncoder {
    static var reviewAccessHub: JSONEncoder {
        let encoder = JSONEncoder()
        return encoder
    }
}

private extension JSONDecoder {
    static var reviewAccessHub: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
