import Foundation
import SwiftUI

// MARK: - Models

struct QueueHealth {
    var reachable: Bool = false
    var pendingCount: Int = 0
    var processingCount: Int = 0
    var doneCount: Int = 0
}

// MARK: - HubStore

@MainActor
final class HubStore: ObservableObject {
    @Published var queueHealth = QueueHealth()
    @Published var matrixReachable: Bool = false
    @Published var matrixVersion: String = ""
    @Published var matrixRooms: [MatrixRoom] = []
    @Published var isLoading = false
    @Published var matrixError: String? = nil
    @Published var hubOwnerMatrixId: String = ""
    @Published var contacts: [VaultContact] = []
    @Published var vaultReachable: Bool = false
    @Published var reviewAccessAdminVerified: Bool = false
    @Published var reviewAccessAdminCapabilities: [String] = []
    @Published var reviewAccessAdminStatus: String = "Not verified"
    @Published var reviewAccessAdminLastVerifiedAt: Date? = nil
    @Published var isVerifyingReviewAccessAdmin = false
    @Published var isUpdatingReviewAccessAdminToken = false

    // Sophia — hub agent account
    @Published var sophiaRooms: [MatrixRoom] = []
    @Published var sophiaError: String? = nil
    let sophia: MatrixClient

    var isHubOwner: Bool {
        guard let userId = matrix.userId, !hubOwnerMatrixId.isEmpty else { return false }
        return userId == hubOwnerMatrixId
    }

    let matrix: MatrixClient

    @AppStorage("vaultPath")   var vaultPath: String = "/Users/bananawalnut/vault"
    @AppStorage("hubEnvPath")  var hubEnvPath: String = "/Users/bananawalnut/repos/hub/.env"
    @AppStorage("hubNamespace") var hubNamespace: String = ""
    @AppStorage("hubNodeURL") var hubNodeURL: String = ReviewAccessHubClient.defaultHubURL.absoluteString
    @AppStorage(HubRemoteAccess.localRootUserDefaultsKey) var hubPathRoot: String = ""
    @AppStorage(HubArtifactMount.userDefaultsKey) var hubArtifactMountsJSON: String = "[]"

    private let queueBase: String

    init(
        queueBase: String  = "http://localhost:8081",
        matrixBase: String = "http://localhost:8008"
    ) {
        self.queueBase = queueBase
        self.matrix    = MatrixClient(baseURL: matrixBase, keyPrefix: "matrix_")
        self.sophia    = MatrixClient(baseURL: matrixBase, keyPrefix: "sophia_")
    }

    var matrixUserId: String? { matrix.userId }
    var matrixLoggedIn: Bool  { matrix.isLoggedIn }
    var effectiveHubPathRoot: URL {
        HubRemoteAccess.localMirrorRoot(from: hubArtifactMountsJSON, rootPath: hubPathRoot)
    }
    var defaultHubNamespace: String {
        HubRemoteAccess.namespace(from: hubArtifactMountsJSON, rootPath: hubPathRoot)
    }
    var effectiveHubNamespace: String {
        return Self.sanitizedNamespace(from: hubNamespace) ?? defaultHubNamespace
    }
    var hubDisplayName: String { effectiveHubNamespace }
    var hubNodeBaseURL: URL {
        URL(string: hubNodeURL.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ReviewAccessHubClient.defaultHubURL
    }

    // MARK: Refresh

    func refresh() async {
        isLoading = true
        async let q: Void = checkQueue()
        async let m: Void = checkMatrixReachability()
        async let i: Void = fetchHubIdentity()
        async let v: Void = fetchContacts()
        _ = await (q, m, i, v)
        if matrix.isLoggedIn {
            await fetchRooms()
        }
        isLoading = false
    }

    func fetchHubIdentity() async {
        guard let url = URL(string: "\(queueBase)/identity") else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let ownerId = json["hub_owner_matrix_id"] as? String {
            hubOwnerMatrixId = ownerId
        }
        if hubNamespace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           HubArtifactMount.load(from: hubArtifactMountsJSON).isEmpty,
           let remoteNamespace = json["hub_namespace"] as? String,
           let sanitized = Self.sanitizedNamespace(from: remoteNamespace) {
            // Keep the remote-reported Hub identity as a bootstrap fallback only.
            // Once a local mirror is configured, effective identity is derived
            // from the mirror root so ZenithOS has one access mechanism.
            hubNamespace = sanitized
        }
    }

    // MARK: Vault contacts

    func fetchContacts() async {
        guard !vaultPath.isEmpty else {
            contacts = []
            vaultReachable = false
            return
        }
        let scanned = VaultScanner.contacts(at: vaultPath)
        vaultReachable = FileManager.default.fileExists(atPath: vaultPath)
        contacts = scanned
    }

    // MARK: Login / Logout

    func login(user: String, password: String) async throws {
        matrixError = nil
        try await matrix.login(user: user, password: password)
        await fetchRooms()
    }

    func register(username: String, password: String) async throws {
        matrixError = nil
        try await matrix.register(username: username, password: password)
        await fetchRooms()
    }

    func logout() async {
        await matrix.logout()
        matrixRooms = []
    }

    // MARK: Private

    private func checkQueue() async {
        guard let url = URL(string: "\(queueBase)/queues") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let queues = json["queues"] as? [[String: Any]],
               let workspace = queues.first(where: { $0["queue_name"] as? String == "workspace" }) {
                queueHealth.reachable       = true
                queueHealth.pendingCount    = workspace["pending"]    as? Int ?? 0
                queueHealth.processingCount = workspace["processing"] as? Int ?? 0
                queueHealth.doneCount       = workspace["done"]       as? Int ?? 0
            } else {
                queueHealth.reachable = true
            }
        } catch {
            queueHealth.reachable = false
        }
    }

    private func checkMatrixReachability() async {
        guard let url = URL(string: "\(matrix.baseURL)/_matrix/federation/v1/version") else { return }
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                matrixReachable = false; return
            }
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let server = json["server"] as? [String: Any],
               let version = server["version"] as? String {
                matrixVersion   = version
            }
            matrixReachable = true
        } catch {
            matrixReachable = false
        }
    }

    func refreshRooms() async {
        await fetchRooms()
    }

    private func fetchRooms() async {
        do {
            matrixRooms = try await matrix.joinedRooms()
        } catch {
            matrixError = error.localizedDescription
        }
    }

    // MARK: Sophia (app service identity — authenticated via AS token from hub .env)

    /// Loads Sophia's AS token from the hub .env and sets it directly —
    /// no login call needed. Synapse recognises the as_token as Sophia's
    /// credential; ?user_id= tells it which virtual user to act as.
    func connectSophia() async {
        sophiaError = nil
        let env = EnvFile.load(at: hubEnvPath)
        guard let asToken = env["SOPHIA_AS_TOKEN"],
              let matrixUser = env["SOPHIA_MATRIX_USER"] else {
            sophiaError = "SOPHIA_AS_TOKEN / SOPHIA_MATRIX_USER not found in \(hubEnvPath)"
            return
        }
        sophia.setAsCredentials(token: asToken, userId: matrixUser)
        await fetchSophiaRooms()
    }

    func refreshSophiaRooms() async {
        // Re-read env on each refresh in case the token was rotated
        if !sophia.isLoggedIn { await connectSophia(); return }
        await fetchSophiaRooms()
    }

    private func fetchSophiaRooms() async {
        guard sophia.isLoggedIn else { return }
        do {
            sophiaRooms = try await sophia.joinedRooms()
            sophiaError = nil
        } catch {
            sophiaError = error.localizedDescription
        }
    }

    func previewHubNamespace(from raw: String) -> String? {
        Self.sanitizedNamespace(from: raw)
    }

    func saveHubNamespace(_ raw: String) {
        hubNamespace = Self.sanitizedNamespace(from: raw) ?? ""
    }

    func resetHubNamespace() {
        hubNamespace = ""
    }

    func saveHubNodeURL(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if URL(string: trimmed) != nil {
            hubNodeURL = trimmed
        } else {
            hubNodeURL = ReviewAccessHubClient.defaultHubURL.absoluteString
        }
        resetReviewAccessVerification(message: "Hub URL changed; verify the connection before using Review Access.")
    }

    func resetHubNodeURL() {
        hubNodeURL = ReviewAccessHubClient.defaultHubURL.absoluteString
        resetReviewAccessVerification(message: "Hub URL reset; verify the connection before using Review Access.")
    }

    func resetReviewAccessVerification(message: String = "Not verified") {
        reviewAccessAdminVerified = false
        reviewAccessAdminCapabilities = []
        reviewAccessAdminStatus = message
        reviewAccessAdminLastVerifiedAt = nil
    }

    func verifyReviewAccessAdminConnection() async {
        isVerifyingReviewAccessAdmin = true
        defer { isVerifyingReviewAccessAdmin = false }
        guard let token = ReviewAccessHubClient.adminTokenFromKeychain()?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            resetReviewAccessVerification(message: ReviewAccessHubClientError.missingAdminToken.localizedDescription)
            return
        }
        await verifyReviewAccessAdminConnection(with: token)
    }

    func updateReviewAccessAdminTokenOnHub(_ rawToken: String) async throws {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw ReviewAccessHubClientError.missingAdminToken
        }
        isUpdatingReviewAccessAdminToken = true
        defer { isUpdatingReviewAccessAdminToken = false }
        let currentToken = ReviewAccessHubClient.adminTokenFromKeychain()?.trimmingCharacters(in: .whitespacesAndNewlines)
        let response = try await ReviewAccessHubClient(baseURL: hubNodeBaseURL).updateAdminTokenOnHub(newToken: token, currentToken: currentToken)
        if response.secretsPrinted {
            throw ReviewAccessHubClientError.secretsPrinted
        }
        try ReviewAccessHubClient.saveAdminTokenToKeychain(token)
        reviewAccessAdminVerified = response.configured && response.capabilities.contains("review_access_admin")
        reviewAccessAdminCapabilities = response.capabilities
        reviewAccessAdminLastVerifiedAt = Date()
        reviewAccessAdminStatus = reviewAccessAdminVerified ? "Updated and verified against \(hubNodeBaseURL.absoluteString)" : "Hub updated the credential but did not grant review_access_admin."
    }

    private func verifyReviewAccessAdminConnection(with token: String) async {
        do {
            let response = try await ReviewAccessHubClient(baseURL: hubNodeBaseURL).verifyAdminToken(token)
            reviewAccessAdminVerified = response.ok && response.capabilities.contains("review_access_admin")
            reviewAccessAdminCapabilities = response.capabilities
            reviewAccessAdminLastVerifiedAt = Date()
            reviewAccessAdminStatus = reviewAccessAdminVerified ? "Verified against \(hubNodeBaseURL.absoluteString)" : "Hub responded but did not grant review_access_admin."
        } catch {
            resetReviewAccessVerification(message: error.localizedDescription)
        }
    }

    nonisolated static func sanitizedNamespace(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var output = ""
        var lastWasSeparator = true

        for scalar in trimmed.lowercased().unicodeScalars {
            switch scalar.value {
            case 97...122, 48...57:
                output.unicodeScalars.append(scalar)
                lastWasSeparator = false
            default:
                if !lastWasSeparator {
                    output.append("-")
                    lastWasSeparator = true
                }
            }
        }

        while output.last == "-" {
            output.removeLast()
        }

        return output.isEmpty ? nil : output
    }
}
