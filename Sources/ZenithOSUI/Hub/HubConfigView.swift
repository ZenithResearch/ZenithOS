import SwiftUI

struct HubConfigView: View {
    @EnvironmentObject private var store: HubStore
    @State private var showLogin = false
    @State private var namespaceDraft = ""
    @State private var hubNodeDraft = ""
    @State private var adminTokenDraft = ""
    @State private var hasAdminToken = false
    @State private var adminTokenStatus: AdminTokenStatus = .idle

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                todosSection
                Divider()
                hubNodeSection
                Divider()
                identitySection
                Divider()
                reviewAccessAdminSection
                Divider()
                matrixSection
                Divider()
                vaultSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Hub Connection")
        .toolbar {
            ToolbarItem {
                Button(action: { Task { await store.refresh() } }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh connection status")
            }
        }
        .task {
            namespaceDraft = store.hubNamespace
            hubNodeDraft = store.hubNodeURL
            refreshAdminTokenStatus()
            await store.refresh()
        }
        .sheet(isPresented: $showLogin) {
            MatrixLoginView(
                homeserver: store.matrix.baseURL,
                onLogin: { user, password in
                    try await store.login(user: user, password: password)
                },
                onRegister: { username, password in
                    try await store.register(username: username, password: password)
                }
            )
        }
    }

    // MARK: - Todos

    private var todosSection: some View {
        HubCard { TodoWidget() }
    }

    // MARK: - Hub Node

    private var hubNodeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Hub Node", icon: "point.3.connected.trianglepath.dotted")

            HubCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("ZenithOS controls one Hub node. Review Access, vault sync, and operator actions target this deployed Hub, not a separate local/remote setting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(alignment: .top, spacing: 10) {
                        TextField("https://hub.zenith-research.ca", text: $hubNodeDraft)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                            .onSubmit(saveHubNodeURL)
                        Button("Save", action: saveHubNodeURL)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(trimmedHubNodeDraft.isEmpty)
                        Button("Reset") {
                            store.resetHubNodeURL()
                            hubNodeDraft = store.hubNodeURL
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    IdentityPreviewRow(label: "Active Hub", value: store.hubNodeBaseURL.absoluteString)
                }
            }
        }
    }

    // MARK: - Identity

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Identity", icon: "at")

            HubCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Namespace")
                        .font(.subheadline.weight(.semibold))

                    Text("This is the stable root name for the hub. ZenithOS uses it as the visible hub root, and it becomes the unique hub ID if you later register with the network registry.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(alignment: .top, spacing: 10) {
                        TextField(store.defaultHubNamespace, text: $namespaceDraft)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                            .onSubmit(saveNamespace)

                        Button("Save", action: saveNamespace)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(!canSaveNamespace)

                        Button("Reset") {
                            store.resetHubNamespace()
                            namespaceDraft = ""
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(store.hubNamespace.isEmpty && namespaceDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    HStack(spacing: 8) {
                        Image(systemName: namespaceStatusIcon)
                            .foregroundStyle(namespaceStatusColor)
                        Text(namespaceStatusText)
                            .font(.caption)
                            .foregroundStyle(namespaceStatusColor)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        IdentityPreviewRow(label: "Effective root", value: effectiveNamespacePreview)
                        IdentityPreviewRow(label: "Bucket route", value: "\(effectiveNamespacePreview)/buckets/{name}")
                        IdentityPreviewRow(label: "Registry ID", value: effectiveNamespacePreview)
                    }
                }
            }
        }
    }


    // MARK: - Review Access Admin

    private var reviewAccessAdminSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Review Access Admin", icon: "key")

            HubCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Label(hasAdminToken ? "Local credential configured" : "No local credential configured", systemImage: hasAdminToken ? "checkmark.circle.fill" : "exclamationmark.triangle")
                            .foregroundStyle(hasAdminToken ? .green : .orange)
                        Spacer()
                        Text(ReviewAccessHubClient.keychainService)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }

                    Text("Use this panel in two modes. Save Local Credential imports a token that already exists on this Hub. Set/Rotate on Hub sends this token to the active Hub node first, then saves it locally only after Hub accepts it. First setup works when the Hub has no admin credential yet; later rotation requires the current local credential to already verify. If the Hub returns 404, deploy/restart the Hub gateway with the Review Access admin endpoints first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(alignment: .top, spacing: 10) {
                        SecureField(hasAdminToken ? "Paste replacement token" : "Paste admin token", text: $adminTokenDraft)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                            .onSubmit(saveAdminToken)

                        Button(hasAdminToken ? "Update Local Credential" : "Save Local Credential", action: saveAdminToken)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(trimmedAdminTokenDraft.isEmpty)

                        Button("Set/Rotate on Hub") {
                            Task { await setAdminTokenOnHub() }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(trimmedAdminTokenDraft.isEmpty || store.isUpdatingReviewAccessAdminToken)

                        Button("Verify Connection") {
                            Task { await store.verifyReviewAccessAdminConnection() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!hasAdminToken || store.isVerifyingReviewAccessAdmin)

                        Button("Reset") {
                            resetAdminToken()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!hasAdminToken && trimmedAdminTokenDraft.isEmpty)
                    }

                    HStack(spacing: 8) {
                        Image(systemName: store.reviewAccessAdminVerified ? "checkmark.seal.fill" : "xmark.seal")
                            .foregroundStyle(store.reviewAccessAdminVerified ? .green : .orange)
                        Text(store.reviewAccessAdminStatus)
                            .font(.caption)
                            .foregroundStyle(store.reviewAccessAdminVerified ? .green : .orange)
                        if let verifiedAt = store.reviewAccessAdminLastVerifiedAt {
                            Text("·")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Text(verifiedAt, style: .relative)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    if !store.reviewAccessAdminCapabilities.isEmpty {
                        Text("Capabilities: \(store.reviewAccessAdminCapabilities.joined(separator: ", "))")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }

                    switch adminTokenStatus {
                    case .idle:
                        Text("Leave the field empty unless you are replacing the current token.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    case .saved:
                        Label("Token saved to Keychain.", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    case .updatedOnHub:
                        Label("Token set on Hub and saved locally.", systemImage: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    case .deleted:
                        Label("Token removed from Keychain.", systemImage: "trash")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    // MARK: - Matrix

    private var matrixSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Matrix", icon: "network")

            HubCard {
                VStack(alignment: .leading, spacing: 10) {
                    // Homeserver status
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            ConnectionRow(
                                label: "localhost:8008",
                                reachable: store.matrixReachable
                            )
                            if !store.matrixVersion.isEmpty {
                                Text("Synapse \(store.matrixVersion)")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                    }

                    Divider()

                    // Account row
                    HStack(spacing: 8) {
                        Image(systemName: "person.circle")
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        if let userId = store.matrixUserId {
                            Text(userId)
                                .font(.body)
                            Spacer()
                            Button("Sign Out") {
                                Task { await store.logout() }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        } else {
                            Text("No account connected")
                                .font(.body)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Connect") { showLogin = true }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(!store.matrixReachable)
                        }
                    }

                    if let err = store.matrixError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    // Rooms
                    if !store.matrixRooms.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Joined Rooms")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            ForEach(store.matrixRooms) { room in
                                HStack(spacing: 6) {
                                    Image(systemName: "bubble.left.and.bubble.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                    Text(room.displayName)
                                        .font(.caption)
                                    Spacer()
                                    Text(room.id)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    } else if store.matrixLoggedIn {
                        Divider()
                        Text("No rooms joined")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // MARK: - Vault

    private var vaultSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Vault", icon: "books.vertical")

            HubCard {
                VStack(alignment: .leading, spacing: 10) {
                    // Path field
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        TextField("Vault path (e.g. /Users/you/repos/vault)", text: store.$vaultPath)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                            .onSubmit { Task { await store.fetchContacts() } }
                        Button("Browse") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.allowsMultipleSelection = false
                            panel.prompt = "Select Vault"
                            if panel.runModal() == .OK, let url = panel.url {
                                store.vaultPath = url.path
                                Task { await store.fetchContacts() }
                            }
                        }
                        .controlSize(.small)
                    }

                    // Status
                    if store.vaultPath.isEmpty {
                        Text("No vault configured")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(store.vaultReachable ? Color.green : Color.red)
                                .frame(width: 8, height: 8)
                            Text(store.vaultReachable ? "Vault found" : "Path not found")
                                .font(.caption)
                                .foregroundStyle(store.vaultReachable ? .green : .red)
                        }
                    }

                    if !store.contacts.isEmpty {
                        Divider()
                        HStack(spacing: 4) {
                            Image(systemName: "person.2")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(store.contacts.count) contact\(store.contacts.count == 1 ? "" : "s") in Rolodex")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            let withMatrix = store.contacts.filter { $0.hasMatrix }.count
                            if withMatrix > 0 {
                                Text("·")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                Text("\(withMatrix) on Matrix")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private var trimmedNamespaceDraft: String {
        namespaceDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var namespacePreview: String? {
        store.previewHubNamespace(from: namespaceDraft)
    }

    private var effectiveNamespacePreview: String {
        namespacePreview ?? store.defaultHubNamespace
    }

    private var canSaveNamespace: Bool {
        trimmedNamespaceDraft.isEmpty || namespacePreview != nil
    }

    private var namespaceStatusText: String {
        if trimmedNamespaceDraft.isEmpty {
            return "Using the default namespace derived from the local hub root: \(store.defaultHubNamespace)"
        }
        guard let namespacePreview else {
            return "Use at least one letter or number. Only lowercase letters, numbers, and hyphens are kept."
        }
        if namespacePreview != trimmedNamespaceDraft {
            return "Will save as \(namespacePreview)"
        }
        return "Valid namespace"
    }

    private var namespaceStatusColor: Color {
        if trimmedNamespaceDraft.isEmpty {
            return .secondary
        }
        return namespacePreview == nil ? .red : .green
    }

    private var namespaceStatusIcon: String {
        if trimmedNamespaceDraft.isEmpty {
            return "info.circle"
        }
        return namespacePreview == nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    }

    private var trimmedAdminTokenDraft: String {
        adminTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedHubNodeDraft: String {
        hubNodeDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func refreshAdminTokenStatus() {
        hasAdminToken = ReviewAccessHubClient.hasAdminTokenInKeychain()
    }

    private func saveAdminToken() {
        do {
            try ReviewAccessHubClient.saveAdminTokenToKeychain(adminTokenDraft)
            adminTokenDraft = ""
            refreshAdminTokenStatus()
            store.resetReviewAccessVerification(message: "Local credential changed; verify the Hub connection before using Review Access.")
            adminTokenStatus = hasAdminToken ? .saved : .deleted
        } catch {
            adminTokenStatus = .failed(error.localizedDescription)
        }
    }

    private func setAdminTokenOnHub() async {
        let token = trimmedAdminTokenDraft
        guard !token.isEmpty else { return }
        do {
            try await store.updateReviewAccessAdminTokenOnHub(token)
            adminTokenDraft = ""
            refreshAdminTokenStatus()
            adminTokenStatus = .updatedOnHub
        } catch {
            adminTokenStatus = .failed(error.localizedDescription)
            store.resetReviewAccessVerification(message: error.localizedDescription)
        }
    }

    private func resetAdminToken() {
        do {
            try ReviewAccessHubClient.deleteAdminTokenFromKeychain()
            adminTokenDraft = ""
            refreshAdminTokenStatus()
            store.resetReviewAccessVerification(message: "Local credential removed; Review Access is disabled until a Hub credential verifies.")
            adminTokenStatus = .deleted
        } catch {
            adminTokenStatus = .failed(error.localizedDescription)
        }
    }

    private func saveNamespace() {
        store.saveHubNamespace(namespaceDraft)
        namespaceDraft = store.hubNamespace
    }

    private func saveHubNodeURL() {
        store.saveHubNodeURL(hubNodeDraft)
        hubNodeDraft = store.hubNodeURL
    }
}

private enum AdminTokenStatus: Equatable {
    case idle
    case saved
    case updatedOnHub
    case deleted
    case failed(String)
}

// MARK: - Sub-components

private struct SectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        Label(title, systemImage: icon)
            .font(.headline)
    }
}

struct HubCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct ConnectionRow: View {
    let label: String
    let reachable: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(reachable ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.body.monospaced())
            Text(reachable ? "connected" : "unreachable")
                .font(.caption)
                .foregroundStyle(reachable ? .green : .red)
        }
    }
}

private struct StatPill: View {
    let label: String
    let value: Int
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Text("\(value)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct IdentityPreviewRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }
}
