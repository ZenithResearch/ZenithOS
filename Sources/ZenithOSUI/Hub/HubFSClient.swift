import Foundation

struct HubFSEntry: Decodable, Equatable, Identifiable {
    enum Kind: String, Decodable {
        case file
        case directory
        case missing
    }

    let path: String
    let name: String
    let kind: Kind
    let exists: Bool?
    let size: Int64?
    let mimeType: String?
    let modifiedAt: Date?
    let digest: String?
    let readable: Bool?
    let ref: String?
    let namespace: String?

    var id: String { ref ?? path }

    enum CodingKeys: String, CodingKey {
        case path
        case name
        case kind
        case exists
        case size
        case mimeType = "mime_type"
        case modifiedAt = "modified_at"
        case digest
        case readable
        case ref
        case namespace
    }
}

struct HubFSManifest: Decodable, Equatable {
    let root: String
    let recursive: Bool
    let truncated: Bool
    let limit: Int?
    let entries: [HubFSEntry]
}

enum HubFSPath {
    static let defaultNamespaces = ["/data"]

    static func normalize(_ rawPath: String) -> String? {
        let expanded = rawPath.hasPrefix("~/")
            ? NSString(string: rawPath).expandingTildeInPath
            : rawPath
        let trimmed = expanded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed).standardizedFileURL.path
        }
        if trimmed.hasPrefix("data/") {
            return URL(fileURLWithPath: "/\(trimmed)").standardizedFileURL.path
        }
        return nil
    }

    static func isHubFSPath(_ rawPath: String, namespaces: [String] = defaultNamespaces) -> Bool {
        guard let normalized = normalize(rawPath) else { return false }
        return namespaces.contains { namespace in
            normalized == namespace || normalized.hasPrefix(namespace + "/")
        }
    }

    static func base64URLEncoded(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

final class HubFSClient {
    let baseURL: URL
    private let reviewAccessClient: ReviewAccessHubClient
    private let decoder: JSONDecoder

    init(baseURL: URL = ReviewAccessHubClient.defaultHubURL) {
        self.baseURL = baseURL
        self.reviewAccessClient = ReviewAccessHubClient(baseURL: baseURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func stat(path: String) async throws -> HubFSEntry {
        let data = try await reviewAccessClient.adminData(
            path: "v1/admin/fs/stat",
            queryItems: [URLQueryItem(name: "path", value: path)]
        )
        return try decoder.decode(HubFSEntry.self, from: data)
    }

    func content(path: String) async throws -> Data {
        try await reviewAccessClient.adminData(
            path: "v1/admin/fs/content",
            queryItems: [URLQueryItem(name: "path", value: path)]
        )
    }

    func contentByPath(_ path: String) async throws -> Data {
        let normalized = HubFSPath.normalize(path) ?? path
        let encoded = HubFSPath.base64URLEncoded(normalized)
        return try await reviewAccessClient.adminData(path: "v1/admin/fs/by-path/\(encoded)/content")
    }

    func list(path: String, recursive: Bool = false) async throws -> HubFSManifest {
        let data = try await reviewAccessClient.adminData(
            path: "v1/admin/fs/list",
            queryItems: [
                URLQueryItem(name: "path", value: path),
                URLQueryItem(name: "recursive", value: recursive ? "true" : "false")
            ]
        )
        return try decoder.decode(HubFSManifest.self, from: data)
    }

    func manifest(path: String, recursive: Bool = true) async throws -> HubFSManifest {
        let data = try await reviewAccessClient.adminData(
            path: "v1/admin/fs/manifest",
            queryItems: [
                URLQueryItem(name: "path", value: path),
                URLQueryItem(name: "recursive", value: recursive ? "true" : "false")
            ]
        )
        return try decoder.decode(HubFSManifest.self, from: data)
    }
}
