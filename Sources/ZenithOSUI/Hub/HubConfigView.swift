import SwiftUI

struct HubConfigView: View {
    @EnvironmentObject private var store: HubStore
    @State private var showLogin = false
    @State private var namespaceDraft = ""
    @State private var hubPathRootDraft = ""
    @State private var hubPathRootMessage: MountLocalRootMessage?
    @State private var hubNodeDraft = ""
    @State private var adminTokenDraft = ""
    @State private var mountRuntimePrefixDraft = ""
    @State private var mountLocalRootDraft = ""
    @State private var mountLabelDraft = ""
    @State private var mountLocalRootMessage: MountLocalRootMessage?
    @State private var hasAdminToken = false
    @State private var adminTokenStatus: AdminTokenStatus = .idle
    @AppStorage(HubRemoteAccess.localRootUserDefaultsKey) private var hubPathRoot: String = ""
    @AppStorage(HubArtifactMount.userDefaultsKey) private var hubArtifactMountsJSON: String = "[]"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                todosSection
                Divider()
                hubNodeSection
                Divider()
                artifactMountsSection
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
            hubPathRootDraft = store.hubPathRoot
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

    // MARK: - Remote Hub Access

    private var artifactMountsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Direct HubFS Access", icon: "externaldrive.connected.to.line.below")
                .help("ZenithOS uses the active Hub's authenticated filesystem API first. Local paths are optional cache/dev fallback only.")

            HubCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("ZenithOS reads Hub runtime paths through authenticated HubFS on the active Hub node. The current bridge uses the Review Access admin token temporarily; secs-magic will replace that auth layer later. Local roots below are optional cache/dev mirrors, not required production setup.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("HubFS is the source of truth. Service-level filesystems can later appear as distinct volumes; the Gateway-owned /data volume is the first direct HubFS volume.")

                    localRootAndNamespaceControls

                    remoteAccessIdentityPreview

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Accessible HubFS volumes")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(mirrorableDirectories) { directory in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Image(systemName: directory.systemImage)
                                    .foregroundStyle(directory.isEnabled(in: artifactMounts) ? Color.accentColor : .secondary)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(directory.name)
                                        .font(.caption.weight(.semibold))
                                    Text(directory.runtimePrefix)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                    Text(directory.statusText(in: artifactMounts))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 0)
                                Text("Active")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.accentColor.opacity(0.12))
                                    .clipShape(Capsule())
                                    .help("Direct HubFS access for this volume is active on the Hub. A local root only adds optional cache/dev mirror behavior.")
                            }
                            .padding(10)
                            .background(Color.secondary.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var localRootAndNamespaceControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Optional local cache / dev mirror")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField(FileStore.hubRoot.path, text: $hubPathRootDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .onChange(of: hubPathRootDraft) { _ in hubPathRootMessage = nil }
                        .help("Optional local cache/dev mirror root. ZenithOS uses authenticated HubFS first; this path is only a local optimization or offline fallback.")
                    Button("Browse") { browseHubPathRoot() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Save Root") { saveHubPathRoot() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!canSaveHubPathRoot)
                    Button("Reset") { resetHubPathRoot() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(hubPathRootDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && hubPathRoot.isEmpty)
                }
                rootStatusRow
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("namespace", text: $namespaceDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .onSubmit(saveNamespace)
                        .help("Optional namespace override. Leave blank to derive it from the selected local root.")
                    Button("Save Namespace", action: saveNamespace)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!canSaveNamespace)
                    Button("Use Root Default") {
                        store.resetHubNamespace()
                        namespaceDraft = ""
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(store.hubNamespace.isEmpty && namespaceDraft.isEmpty)
                }
                HStack(spacing: 6) {
                    Image(systemName: namespaceStatusIcon)
                    Text(namespaceStatusText)
                }
                .font(.caption2)
                .foregroundStyle(namespaceStatusColor)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private var rootStatusRow: some View {
        if let hubPathRootMessage {
            HStack(spacing: 6) {
                Image(systemName: hubPathRootMessage.icon)
                Text(hubPathRootMessage.text)
            }
            .font(.caption2)
            .foregroundStyle(hubPathRootMessage.color)
        } else {
            Text("Local cache: \(HubRemoteAccess.selectedRoot(from: hubPathRootDraft.isEmpty ? hubPathRoot : hubPathRootDraft).path). HubFS remains primary; /data attaches here only when using local cache/dev mirror fallback.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var localMountDirectoryStatusRow: some View {
        if trimmedMountLocalRootDraft.isEmpty {
            Text("Browse to an existing local mirror root, or type a new absolute directory path and create it. This directory becomes ZenithOS's effective Hub root and namespace source when saved.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .help("The local directory is where ZenithOS will look for files after replacing the Hub/runtime prefix. It can be an existing mount point or a directory you create now.")
        } else if let mountLocalRootMessage {
            HStack(spacing: 6) {
                Image(systemName: mountLocalRootMessage.icon)
                Text(mountLocalRootMessage.text)
            }
            .font(.caption2)
            .foregroundStyle(mountLocalRootMessage.color)
            .help("Status for the currently entered local mirror directory.")
        } else if mountLocalRootExists {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                Text("Directory exists and can be used as the local mirror target.")
            }
            .font(.caption2)
            .foregroundStyle(.green)
            .help("The local path exists and is a directory, so it can be saved as the destination for this mount mapping.")
        } else if mountLocalRootCanCreate {
            HStack(spacing: 6) {
                Image(systemName: "folder.badge.plus")
                Text("Directory does not exist yet. Create it before adding the mount.")
            }
            .font(.caption2)
            .foregroundStyle(.orange)
            .help("The local path is absolute but does not exist yet. Use Create to make it before saving the mount.")
        } else {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("Enter an absolute local directory path.")
            }
            .font(.caption2)
            .foregroundStyle(.red)
            .help("Local mirror directories must be absolute paths. They are optional in the simple mirrorable-directory flow.")
        }
    }

    // MARK: - Identity

    private var remoteAccessIdentityPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(Color.accentColor)
                Text("Authenticated HubFS")
                    .font(.subheadline.weight(.semibold))
            }
            Text("Mirror eligibility is directory-based. A local mirror root is optional; when absent, ZenithOS uses Hub-served artifact content instead of inventing a filesystem root.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                IdentityPreviewRow(label: "Active Hub", value: store.hubNodeBaseURL.absoluteString)
                IdentityPreviewRow(label: "Local mirror root", value: effectiveHubPathRootPreview)
                IdentityPreviewRow(label: "Effective namespace", value: store.effectiveHubNamespace)
                IdentityPreviewRow(label: "Mirrorable dirs", value: HubRemoteAccess.routeDescription(from: hubArtifactMountsJSON))
                IdentityPreviewRow(label: "Registry ID", value: store.effectiveHubNamespace)
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // Standalone identity editing intentionally removed: effective identity is part of Remote Hub Access.


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
                        TextField("Vault path (e.g. ~/repos/vault)", text: store.$vaultPath)
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

    private var effectiveHubPathRootPreview: String {
        HubRemoteAccess.localMirrorRoot(from: hubArtifactMountsJSON, rootPath: hubPathRoot).path
    }

    private var trimmedHubPathRootDraft: String {
        hubPathRootDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var expandedHubPathRootDraft: String {
        guard !trimmedHubPathRootDraft.isEmpty else { return "" }
        return NSString(string: trimmedHubPathRootDraft).expandingTildeInPath
    }

    private var hubPathRootExists: Bool {
        guard !expandedHubPathRootDraft.isEmpty else { return true }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: expandedHubPathRootDraft, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    private var canSaveHubPathRoot: Bool {
        trimmedHubPathRootDraft.isEmpty || (expandedHubPathRootDraft.hasPrefix("/") && hubPathRootExists)
    }

    private var canSaveNamespace: Bool {
        trimmedNamespaceDraft.isEmpty || namespacePreview != nil
    }

    private var namespaceStatusText: String {
        if trimmedNamespaceDraft.isEmpty {
            return "Using the default namespace derived from the selected local root: \(store.defaultHubNamespace)"
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

    private let mirrorableDirectories = [
        MirrorableHubDirectory(
            name: "Data",
            runtimePrefix: "/data",
            label: "Data",
            systemImage: "externaldrive"
        ),
    ]

    private var artifactMounts: [HubArtifactMount] {
        HubRemoteAccess.mappings(from: hubArtifactMountsJSON, rootPath: hubPathRoot)
    }

    private var trimmedMountRuntimePrefixDraft: String {
        mountRuntimePrefixDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedMountRuntimePrefixDraft: String {
        HubArtifactMount.normalizeRuntimePrefix(trimmedMountRuntimePrefixDraft)
    }

    private var trimmedMountLocalRootDraft: String {
        mountLocalRootDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var expandedMountLocalRootDraft: String {
        guard !trimmedMountLocalRootDraft.isEmpty else { return "" }
        return NSString(string: trimmedMountLocalRootDraft).expandingTildeInPath
    }

    private var mountLocalRootExists: Bool {
        guard !expandedMountLocalRootDraft.isEmpty else { return false }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: expandedMountLocalRootDraft, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    private var mountLocalRootCanCreate: Bool {
        guard !expandedMountLocalRootDraft.isEmpty, expandedMountLocalRootDraft.hasPrefix("/") else { return false }
        return !mountLocalRootExists
    }

    private var canAddArtifactMount: Bool {
        !normalizedMountRuntimePrefixDraft.isEmpty && mountLocalRootExists
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

    private func setMirrorableDirectory(_ directory: MirrorableHubDirectory, enabled: Bool) {
        let normalizedPrefix = HubArtifactMount.normalizeRuntimePrefix(directory.runtimePrefix)
        var next = artifactMounts.filter { $0.normalizedRuntimePrefix != normalizedPrefix }
        if enabled {
            next.append(HubArtifactMount(runtimePrefix: normalizedPrefix, localRoot: "", label: directory.label))
        }
        hubArtifactMountsJSON = HubArtifactMount.encode(HubArtifactMount.normalized(next))
        store.resetHubNamespace()
        namespaceDraft = ""
    }

    private func addArtifactMount() {
        guard canAddArtifactMount else { return }
        let mount = HubArtifactMount(
            runtimePrefix: normalizedMountRuntimePrefixDraft,
            localRoot: expandedMountLocalRootDraft,
            label: mountLabelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let next = HubArtifactMount.normalized(artifactMounts.filter { $0.normalizedRuntimePrefix != mount.normalizedRuntimePrefix } + [mount])
        hubArtifactMountsJSON = HubArtifactMount.encode(next)
        store.resetHubNamespace()
        namespaceDraft = ""
        clearArtifactMountDrafts()
    }

    private func removeArtifactMount(_ mount: HubArtifactMount) {
        let next = artifactMounts.filter { $0.id != mount.id }
        hubArtifactMountsJSON = HubArtifactMount.encode(next)
    }

    private func clearArtifactMountDrafts() {
        mountRuntimePrefixDraft = ""
        mountLocalRootDraft = ""
        mountLabelDraft = ""
        mountLocalRootMessage = nil
    }

    private func browseArtifactMountLocalRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Mount Directory"
        if panel.runModal() == .OK, let url = panel.url {
            mountLocalRootDraft = url.path
            mountLocalRootMessage = .success("Selected local mirror directory.")
        }
    }

    private func createArtifactMountLocalRoot() {
        guard mountLocalRootCanCreate else { return }
        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: expandedMountLocalRootDraft),
                withIntermediateDirectories: true
            )
            mountLocalRootDraft = expandedMountLocalRootDraft
            mountLocalRootMessage = .success("Created local mirror directory.")
        } catch {
            mountLocalRootMessage = .failure("Could not create directory: \(error.localizedDescription)")
        }
    }

    private func saveNamespace() {
        store.saveHubNamespace(namespaceDraft)
        namespaceDraft = store.hubNamespace
    }

    private func browseHubPathRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Hub Root"
        if panel.runModal() == .OK, let url = panel.url {
            hubPathRootDraft = url.path
            hubPathRootMessage = .success("Selected local Hub root.")
        }
    }

    private func saveHubPathRoot() {
        guard canSaveHubPathRoot else { return }
        hubPathRoot = expandedHubPathRootDraft
        store.hubPathRoot = expandedHubPathRootDraft
        hubPathRootDraft = expandedHubPathRootDraft
        hubPathRootMessage = .success(trimmedHubPathRootDraft.isEmpty ? "Using fallback Hub root." : "Saved local Hub root.")
    }

    private func resetHubPathRoot() {
        hubPathRoot = ""
        store.hubPathRoot = ""
        hubPathRootDraft = ""
        hubPathRootMessage = .success("Reset to fallback Hub root.")
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

private enum MountLocalRootMessage: Equatable {
    case success(String)
    case failure(String)

    var text: String {
        switch self {
        case .success(let message), .failure(let message): return message
        }
    }

    var icon: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .success: return .green
        case .failure: return .red
        }
    }
}

private struct MirrorableHubDirectory: Identifiable {
    var id: String { runtimePrefix }
    let name: String
    let runtimePrefix: String
    let label: String
    let systemImage: String

    func isEnabled(in mounts: [HubArtifactMount]) -> Bool {
        let normalizedPrefix = HubArtifactMount.normalizeRuntimePrefix(runtimePrefix)
        return mounts.contains { $0.normalizedRuntimePrefix == normalizedPrefix }
    }

    func statusText(in mounts: [HubArtifactMount]) -> String {
        let normalizedPrefix = HubArtifactMount.normalizeRuntimePrefix(runtimePrefix)
        guard let mount = mounts.first(where: { $0.normalizedRuntimePrefix == normalizedPrefix }) else {
            return "Disabled. Paths under this Hub directory are not mirror-eligible."
        }
        if mount.hasLocalRoot {
            return "Enabled with local mirror root: \(mount.normalizedLocalRootURL.path)"
        }
        return "Enabled. No local root is required; ZenithOS will use Hub-served artifact content when available."
    }
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
