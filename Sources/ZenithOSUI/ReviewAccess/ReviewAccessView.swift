import SwiftUI
import AppKit

private enum ReviewAccessOperationMode: String, CaseIterable, Identifiable {
    case replaceExisting
    case createNew

    var id: String { rawValue }

    var label: String {
        switch self {
        case .replaceExisting:
            return "Replace existing access record"
        case .createNew:
            return "Create new access record"
        }
    }
}

private enum ReviewAccessPolicyTemplate {
    case localhost
    case custom
}


private enum ReviewAccessPreflightStatus: Equatable {
    case notRun
    case running
    case accepted
    case rejected(String)
    case unavailable(String)

    var label: String {
        switch self {
        case .notRun: return "Not run"
        case .running: return "Running…"
        case .accepted: return "Server OK"
        case .rejected: return "Server rejected"
        case .unavailable: return "Unavailable"
        }
    }
}

enum PolicyRowBadge: String, CaseIterable, Equatable, Hashable {
    case canonical
    case edited
    case stale
    case invalid
    case serverOK = "server-ok"
    case serverRejected = "server-rejected"

    var label: String { rawValue }
}

struct PolicyRowStatusViewModel: Equatable {
    var badges: [PolicyRowBadge]
    var errors: [String]

    var isValid: Bool { !badges.contains(.invalid) && !badges.contains(.serverRejected) }

    static func build(
        policy: ReviewAccessPolicy,
        projectID rawProjectID: String,
        canonicalPolicies: [ReviewAccessPolicy],
        localErrors: [String] = [],
        serverAccepted: Bool? = nil
    ) -> PolicyRowStatusViewModel {
        var badges: [PolicyRowBadge] = []
        var errors = localErrors
        let normalizedPolicy = normalized(policy)
        let canonicalRows = Set(canonicalPolicies.map(normalized))
        if isKnownStale(policy, projectID: rawProjectID) {
            badges.append(.stale)
            errors.append("Known stale policy; reset to canonical policies before rotating.")
        } else if canonicalRows.contains(normalizedPolicy) {
            badges.append(.canonical)
        } else {
            badges.append(.edited)
        }
        if !localErrors.isEmpty || policy.deploymentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || policy.allowedOrigin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || policy.subjectPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            badges.append(.invalid)
        }
        if let serverAccepted {
            badges.append(serverAccepted ? .serverOK : .serverRejected)
            if !serverAccepted {
                errors.append("Hub preflight rejected this policy.")
            }
        }
        return PolicyRowStatusViewModel(badges: unique(badges), errors: errors)
    }

    private static func unique(_ badges: [PolicyRowBadge]) -> [PolicyRowBadge] {
        var seen = Set<PolicyRowBadge>()
        return badges.filter { seen.insert($0).inserted }
    }

    static func normalized(_ policy: ReviewAccessPolicy) -> String {
        [
            policy.deploymentID.trimmingCharacters(in: .whitespacesAndNewlines),
            policy.allowedOrigin.trimmingCharacters(in: .whitespacesAndNewlines),
            policy.subjectPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        ].joined(separator: "\u{1f}")
    }

    static func isKnownStale(_ policy: ReviewAccessPolicy, projectID rawProjectID: String) -> Bool {
        let projectID = rawProjectID.trimmingCharacters(in: .whitespacesAndNewlines)
        let deploymentID = policy.deploymentID.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = policy.subjectPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if projectID == ReviewAccessProjectPreset.swrlWeb.projectID {
            let staleLocalID = "swrl" + "-local"
            let staleProductionWildcard = "https://www.collectswirls.com" + "*"
            return deploymentID == staleLocalID || subject == staleProductionWildcard
        }
        if projectID == ReviewAccessProjectPreset.gallery.projectID {
            return ["gallery-dev", "gallery-prod", "gallery-production"].contains(deploymentID)
        }
        return false
    }
}

struct ReviewAccessView: View {
    @EnvironmentObject private var hub: HubStore
    @StateObject private var reviewStore = ReviewAccessStore()
    @StateObject private var runtimeConfigStore = HubRuntimeConfigStore()

    @State private var operationMode: ReviewAccessOperationMode = .replaceExisting
    @State private var selectedConfigID: ReviewAccessConfig.ID?
    @State private var selectedContactID: VaultContact.ID?
    @State private var clientName = ""
    @State private var clientSlug = ""
    @State private var accessLabel = ""
    @State private var projectID = ReviewAccessProjectPreset.gallery.projectID
    @State private var projectName = ReviewAccessProjectPreset.gallery.projectName
    @State private var selectedPreset: ReviewAccessProjectPreset = .gallery
    @State private var policies = ReviewAccessProjectPreset.gallery.defaultPolicies
    @State private var allowEditedReplacementMetadata = false
    @State private var manualCode = ""
    @State private var oneTimeCode: String?
    @State private var statusMessage: String?
    @State private var debugLog: String?
    @State private var debugDrawerExpanded = false
    @State private var preflightStatus: ReviewAccessPreflightStatus = .notRun
    @State private var preflightFingerprint: String?
    @State private var preflightPolicyKeys = Set<String>()
    @State private var isPreflighting = false
    @State private var isSubmitting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                HubCard { hubStatusBar }
                HubCard { HubRuntimeConfigView(store: runtimeConfigStore, hubBaseURL: hub.hubNodeBaseURL) }
                HubCard { reviewerTargetCard }
                HubCard { projectPresetCard }
                HubCard { policiesSection }
                HubCard { actionFooterSection }
                if !reviewStore.configs.isEmpty {
                    HubCard { savedConfigsSection }
                }
                HubCard { debugDrawerSection }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Review Access")
        .task { await hub.fetchContacts() }
        .onAppear { normalizeOperationMode() }
        .onChange(of: selectedContactID) { _ in applySelectedContactDefaults() }
        .onChange(of: selectedConfigID) { _ in applySelectedConfigDefaults() }
        .onChange(of: operationMode) { _ in applyOperationModeChange() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Reviewer access codes", systemImage: "key.viewfinder")
                .font(.title2.weight(.semibold))
            Text("Pick the reviewer row, then generate a fresh reviewer key or paste the existing one. ZenithOS sends the allowed environment rows shown below, where you can add or edit production, preview, staging, and localhost origins before rotating.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var hubStatusBar: some View { hubConnectionSection }

    private var reviewerTargetCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Reviewer target", systemImage: "person.text.rectangle")
                .font(.headline)
            Text("Choose whether to create a new review-access row or replace a saved Hub row. Create mode warns when the local safe metadata already contains the previewed access-code ID.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Mode", selection: $operationMode) {
                Text("Create new row").tag(ReviewAccessOperationMode.createNew)
                Text("Replace selected row").tag(ReviewAccessOperationMode.replaceExisting)
            }
            .pickerStyle(.segmented)
            .disabled(reviewStore.configs.isEmpty)

            if !reviewStore.configs.isEmpty, effectiveOperationMode == .replaceExisting {
                Picker("Existing row to replace", selection: $selectedConfigID) {
                    Text("Choose existing row…").tag(ReviewAccessConfig.ID?.none)
                    ForEach(reviewStore.configs) { config in
                        Text("\(config.accessLabel) — \(config.accessCodeID)")
                            .tag(ReviewAccessConfig.ID?.some(config.id))
                    }
                }
                .pickerStyle(.menu)
            }

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Reviewer")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if hub.contacts.isEmpty {
                        Button("Refresh Rolodex") { Task { await hub.fetchContacts() } }
                            .controlSize(.small)
                    } else {
                        Picker("Rolodex person", selection: $selectedContactID) {
                            Text("Choose a person…").tag(VaultContact.ID?.none)
                            ForEach(hub.contacts) { contact in
                                Text(contact.displayName).tag(VaultContact.ID?.some(contact.id))
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    TextField("Reviewer name", text: $clientName)
                        .textFieldStyle(.roundedBorder)
                    TextField("reviewer-slug", text: $clientSlug)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                    TextField("Access label returned to apps, e.g. Dan Admin", text: $accessLabel)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Access-code ID preview")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(targetAccessCodeID)
                        .font(.caption.weight(.semibold).monospaced())
                        .textSelection(.enabled)
                    Text("Access label: \(effectiveAccessLabel)")
                        .font(.caption.monospaced())
                    createModeExistingRowWarning
                    if let selectedConfig, effectiveOperationMode == .replaceExisting {
                        metadataSummary(for: selectedConfig)
                    }
                }
            }
            Text("For SWRL Web admin login, use the label `Dan Admin` or `SWRL Admin`; `swrl-web` checks this label server-side after Hub auth succeeds.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            mismatchWarning
        }
    }

    private var projectPresetCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Project preset", systemImage: "rectangle.connected.to.line.below")
                .font(.headline)
            Text("Pick a canonical preset, edit project identity when needed, or reset stale saved policy metadata back to the canonical rows Hub expects.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Picker("Preset", selection: $selectedPreset) {
                    ForEach(ReviewAccessProjectPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .pickerStyle(.menu)
                Button("Apply preset") { applyProjectPreset(selectedPreset) }
                    .controlSize(.small)
                Button("Reset to canonical policies") { resetToCanonicalPolicies() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Project ID").foregroundStyle(.secondary)
                    TextField("gallery", text: $projectID)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                }
                GridRow {
                    Text("Project name").foregroundStyle(.secondary)
                    TextField("Gallery", text: $projectName)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Project slug").foregroundStyle(.secondary)
                    Text(ReviewAccessCodeFactory.slug(from: projectID))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            canonicalEnvironmentsSummary
        }
    }

    private var simpleTargetSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Review target", systemImage: "person.text.rectangle")
                .font(.headline)
            Text("Normal flow: select the saved reviewer access row, choose the project preset if needed, then edit the allowed environments below before rotating the reviewer key.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                Text(effectiveOperationMode == .replaceExisting ? "Mode: replace an existing Hub review-access row" : "Mode: create a new Hub review-access row")
                    .font(.subheadline.weight(.semibold))
                Text(effectiveOperationMode == .replaceExisting ? "Use this when the access row already exists in Hub and you want to rotate its reviewer key or repair its allowed environments." : "Use this when you want Hub to create the access row/policy record from the reviewer slug and project preset. The row preview below is what Hub will create or overwrite if it already exists.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Row ID: \(targetAccessCodeID)")
                    .font(.caption.weight(.semibold).monospaced())
                    .textSelection(.enabled)
                Text("Access label: \(effectiveAccessLabel)")
                    .font(.caption.weight(.semibold).monospaced())
                    .textSelection(.enabled)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((effectiveOperationMode == .replaceExisting ? Color.accentColor : Color.green).opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            if reviewStore.configs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No saved access rows in ZenithOS.")
                        .font(.subheadline.weight(.semibold))
                    Text("You are already in create-new mode. Fill reviewer/project fields, then generate a reviewer key below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                HStack(alignment: .center, spacing: 12) {
                    Picker("Existing row to replace", selection: $selectedConfigID) {
                        Text("Choose existing row…").tag(ReviewAccessConfig.ID?.none)
                        ForEach(reviewStore.configs) { config in
                            Text("\(config.accessLabel) — \(config.accessCodeID)")
                                .tag(ReviewAccessConfig.ID?.some(config.id))
                        }
                    }
                    .pickerStyle(.menu)

                    Button("Create new Hub row") { createNewRecordFromCurrentForm() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                    Button(role: .destructive) { clearSavedRecords() } label: {
                        Text("Clear local saved rows")
                    }
                    .controlSize(.small)
                }

                if let selectedConfig, effectiveOperationMode == .replaceExisting {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Replacing row: \(selectedConfig.accessCodeID)")
                            .font(.caption.weight(.semibold).monospaced())
                        Text("Replacement preserves this row ID. To create a separate row, click “Create new Hub row” and change the reviewer slug or project before generating.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(Color.accentColor.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                } else if effectiveOperationMode == .createNew {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Creating row: \(targetAccessCodeID)")
                            .font(.caption.weight(.semibold).monospaced())
                        Text("Hub will create this review-access row if it does not exist. If it already exists, Hub treats the request as a rotate/upsert for that row.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(Color.green.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }

            Divider()

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Reviewer")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if hub.contacts.isEmpty {
                        Button("Refresh Rolodex") { Task { await hub.fetchContacts() } }
                            .controlSize(.small)
                    } else {
                        Picker("Rolodex person", selection: $selectedContactID) {
                            Text("Choose a person…").tag(VaultContact.ID?.none)
                            ForEach(hub.contacts) { contact in
                                Text(contact.displayName).tag(VaultContact.ID?.some(contact.id))
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    TextField("Reviewer name", text: $clientName)
                        .textFieldStyle(.roundedBorder)
                    TextField("reviewer-slug", text: $clientSlug)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                    TextField("Access label returned to apps, e.g. Dan Admin", text: $accessLabel)
                        .textFieldStyle(.roundedBorder)
                    Text("For SWRL Web admin login, use the label `Dan Admin` or `SWRL Admin`; `swrl-web` checks this label server-side after Hub auth succeeds.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Project")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack {
                        Picker("Preset", selection: $selectedPreset) {
                            ForEach(ReviewAccessProjectPreset.allCases) { preset in
                                Text(preset.label).tag(preset)
                            }
                        }
                        .pickerStyle(.menu)
                        Button("Apply") { applyProjectPreset(selectedPreset) }
                            .controlSize(.small)
                    }
                    TextField("project-id", text: $projectID)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                    TextField("Project name", text: $projectName)
                        .textFieldStyle(.roundedBorder)
                }
            }

            canonicalEnvironmentsSummary
        }
    }

    @ViewBuilder
    private var createModeExistingRowWarning: some View {
        if effectiveOperationMode == .createNew,
           reviewStore.configs.contains(where: { $0.accessCodeID == targetAccessCodeID }) {
            Label("A saved local row already uses this access-code ID. Hub may treat create as a rotate/upsert for that row.", systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }

    private var canonicalEnvironmentsSummary: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Allowed environments sent to Hub")
                .font(.caption.weight(.semibold))
            ForEach(effectiveRotationPolicies) { policy in
                Text("• \(policy.deploymentID) · \(policy.allowedOrigin) → \(policy.subjectPattern)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var hubConnectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Hub Connection", systemImage: hub.reviewAccessAdminVerified ? "checkmark.seal.fill" : "xmark.seal")
                .font(.headline)
                .foregroundStyle(hub.reviewAccessAdminVerified ? .green : .orange)
            Text("Review Access updates the active Hub node. Rotation is disabled until Hub Connection verifies that this deployed Hub accepts the local admin credential.")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("Active Hub: \(hub.hubNodeBaseURL.absoluteString)")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Text(hub.reviewAccessAdminStatus)
                    .font(.caption)
                    .foregroundStyle(hub.reviewAccessAdminVerified ? .green : .orange)
                if !hub.reviewAccessAdminCapabilities.isEmpty {
                    Text("Capabilities: \(hub.reviewAccessAdminCapabilities.joined(separator: ", "))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Verify Hub Connection") {
                    Task { await hub.verifyReviewAccessAdminConnection() }
                }
                .controlSize(.small)
                .disabled(hub.isVerifyingReviewAccessAdmin)
                Text("Change the Hub URL or local credential in Hub Connection.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var operationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Operation", systemImage: "arrow.triangle.2.circlepath")
                .font(.headline)
            Text("Choose whether this request replaces a selected existing access row or creates a new row derived from the form. The final target is repeated beside the code action before anything is sent to Hub.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Operation", selection: $operationMode) {
                ForEach(ReviewAccessOperationMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(reviewStore.configs.isEmpty)

            if reviewStore.configs.isEmpty {
                Text("No saved safe metadata exists yet, so ZenithOS is in create-new mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if effectiveOperationMode == .replaceExisting {
                replaceExistingControls
            } else {
                createNewControls
            }
        }
    }

    private var replaceExistingControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Existing record", selection: $selectedConfigID) {
                Text("Choose an access record…").tag(ReviewAccessConfig.ID?.none)
                ForEach(reviewStore.configs) { config in
                    Text("\(config.accessLabel) — \(config.accessCodeID)")
                        .tag(ReviewAccessConfig.ID?.some(config.id))
                }
            }
            .pickerStyle(.menu)

            if let selectedConfig {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Replacing existing access record")
                        .font(.subheadline.weight(.semibold))
                    Text("The generated or entered code will overwrite this selected row. The access row ID is preserved from saved metadata; it is not derived from the form while replace mode is active.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    metadataSummary(for: selectedConfig)
                    HStack {
                        Button("Reload selected metadata") { applyConfigToForm(selectedConfig) }
                            .controlSize(.small)
                        Button("Create new record instead") { createNewRecordFromCurrentForm() }
                            .controlSize(.small)
                    }
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                Text("Select the existing review-access row before replacing a code. Replace actions stay disabled until a row is selected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            mismatchWarning
        }
    }

    private var createNewControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Creating new access record")
                .font(.subheadline.weight(.semibold))
            Text("No existing access row will be overwritten. The access row below is derived from the current client slug and project ID.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("New access row preview: \(targetAccessCodeID)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var mismatchWarning: some View {
        if !selectedConfigMismatches.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Metadata differences", systemImage: "info.circle")
                    .font(.subheadline.weight(.semibold))
                Text("Replacement uses the selected access row ID and the final target shown in the code section. Differences here are informational so stale saved metadata does not block policy repair.")
                    .font(.caption)
                ForEach(selectedConfigMismatches, id: \.self) { mismatch in
                    Text("• \(mismatch)")
                        .font(.caption2.monospaced())
                }
                HStack {
                    if let selectedConfig {
                        Button("Reload selected metadata") { applyConfigToForm(selectedConfig) }
                            .controlSize(.small)
                    }
                    Button("Create new record from current form") { createNewRecordFromCurrentForm() }
                        .controlSize(.small)
                }
            }
            .foregroundStyle(.secondary)
            .padding(10)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private var reviewerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Reviewer", systemImage: "person.crop.circle")
                .font(.headline)
            Text(effectiveOperationMode == .replaceExisting ? "Loaded from the selected access record. Edits here are treated as metadata changes and must match the selected target before replacement is enabled." : "Choose a Rolodex person or enter client metadata for the new access record.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if hub.contacts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No rolodex contacts loaded from \(hub.vaultPath).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Refresh Rolodex") { Task { await hub.fetchContacts() } }
                        .controlSize(.small)
                }
            } else {
                Picker("Rolodex person", selection: $selectedContactID) {
                    Text("Choose a person…").tag(VaultContact.ID?.none)
                    ForEach(hub.contacts) { contact in
                        Text(contact.displayName).tag(VaultContact.ID?.some(contact.id))
                    }
                }
                .pickerStyle(.menu)
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Client name").foregroundStyle(.secondary)
                    TextField("Dan Prota", text: $clientName)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Client slug").foregroundStyle(.secondary)
                    TextField("dan-prota", text: $clientSlug)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                }
            }
        }
    }

    private var projectSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Project", systemImage: "rectangle.connected.to.line.below")
                .font(.headline)
            Text(effectiveOperationMode == .replaceExisting ? "Project identity should match the selected access record unless you explicitly allow edited replacement metadata." : "Choose a project preset or enter project metadata for the new access row.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Picker("Preset", selection: $selectedPreset) {
                    ForEach(ReviewAccessProjectPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .pickerStyle(.menu)
                Button("Apply preset") { applyProjectPreset(selectedPreset) }
                    .controlSize(.small)
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Project ID").foregroundStyle(.secondary)
                    TextField("gallery", text: $projectID)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                }
                GridRow {
                    Text("Project name").foregroundStyle(.secondary)
                    TextField("Gallery", text: $projectName)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private var policiesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Allowed environments", systemImage: "network.badge.shield.half.filled")
                    .font(.headline)
                Spacer()
                Button("Add Gallery defaults") { applyProjectPreset(.gallery) }
                    .controlSize(.small)
                Button("Add Localhost") { addPolicy(.localhost) }
                    .controlSize(.small)
                Button("Add Custom Policy") { addPolicy(.custom) }
                    .controlSize(.small)
            }
            Text("A reviewer code is the identity/secret. Policies are the explicit production, preview, staging, or local origins where that code is allowed to work. This replaces dev bypasses with native Hub policy rows.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if policies.isEmpty {
                Text("Add at least one allowed environment before rotating a code.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            ForEach($policies) { $policy in
                policyEditor(policy: $policy)
            }

            if !policyValidationMessages.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Policy validation", systemImage: "exclamationmark.triangle")
                        .font(.caption.weight(.semibold))
                    ForEach(policyValidationMessages, id: \.self) { message in
                        Text("• \(message)")
                            .font(.caption2.monospaced())
                    }
                }
                .foregroundStyle(.orange)
                .padding(10)
                .background(Color.orange.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func policyEditor(policy: Binding<ReviewAccessPolicy>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Production", text: policy.label)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.weight(.medium))
                Text(policy.wrappedValue.allowedOrigin.isEmpty ? "origin required" : policy.wrappedValue.allowedOrigin)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Duplicate") { duplicatePolicy(policy.wrappedValue) }
                    .controlSize(.small)
                Button(role: .destructive) { removePolicy(policy.wrappedValue) } label: {
                    Text("Remove")
                }
                .controlSize(.small)
            }
            policyStatusBadges(for: policy.wrappedValue)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Deployment ID").foregroundStyle(.secondary)
                    TextField("gallery-production", text: policy.deploymentID)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                }
                GridRow {
                    Text("Deployment slug").foregroundStyle(.secondary)
                    TextField("gallery-production", text: policy.deploymentSlug)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                }
                GridRow {
                    Text("Allowed origin").foregroundStyle(.secondary)
                    TextField("https://gal-ler-y.com", text: policy.allowedOrigin)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                }
                GridRow {
                    Text("Subject pattern").foregroundStyle(.secondary)
                    TextField("https://gal-ler-y.com/*", text: policy.subjectPattern)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func policyStatusBadges(for policy: ReviewAccessPolicy) -> some View {
        let status = policyRowStatus(for: policy)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                ForEach(status.badges, id: \.self) { badge in
                    Text(badge.label)
                        .font(.caption2.weight(.semibold).monospaced())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(policyBadgeColor(badge).opacity(0.16))
                        .foregroundStyle(policyBadgeColor(badge))
                        .clipShape(Capsule())
                }
            }
            ForEach(status.errors, id: \.self) { error in
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func policyRowStatus(for policy: ReviewAccessPolicy) -> PolicyRowStatusViewModel {
        let preset = ReviewAccessProjectPreset.allCases.first { $0.projectID == projectID.trimmingCharacters(in: .whitespacesAndNewlines) } ?? selectedPreset
        return PolicyRowStatusViewModel.build(
            policy: policy,
            projectID: projectID,
            canonicalPolicies: preset.defaultPolicies,
            localErrors: localValidationMessages(for: policy)
        )
    }

    private func localValidationMessages(for policy: ReviewAccessPolicy) -> [String] {
        var messages: [String] = []
        let label = policy.label.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Policy"
        let deploymentID = policy.deploymentID.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = policy.allowedOrigin.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = policy.subjectPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if deploymentID.isEmpty { messages.append("\(label): deployment ID is required") }
        if origin.isEmpty { messages.append("\(label): allowed origin is required") }
        if subject.isEmpty { messages.append("\(label): subject pattern is required") }
        return messages
    }

    private func policyBadgeColor(_ badge: PolicyRowBadge) -> Color {
        switch badge {
        case .canonical, .serverOK:
            return .green
        case .edited:
            return .accentColor
        case .stale, .invalid, .serverRejected:
            return .orange
        }
    }

    private var actionFooterSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(effectiveOperationMode == .replaceExisting ? "Replace reviewer code" : "Create reviewer code", systemImage: "lock.rectangle")
                .font(.headline)
            Text("This is the only secret step. The reviewer key is either generated by Hub or pasted once, then Hub stores only its hash. ZenithOS keeps safe metadata only.")
                .font(.caption)
                .foregroundStyle(.secondary)

            rotationSummary
            preflightSection
            rotationReadinessSummary

            VStack(alignment: .leading, spacing: 10) {
                Text("Generate a fresh reviewer key")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Button(generateButtonTitle) { Task { await generateCode() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canRotate)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Or paste the existing reviewer key")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    SecureField("Paste existing reviewer key", text: $manualCode)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .frame(minWidth: 360, maxWidth: 520)
                        .disabled(isSubmitting)
                    Button(providedCodeButtonTitle) { Task { await useManualCode() } }
                        .buttonStyle(.bordered)
                        .disabled(!canRotate || manualCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("Use this when the person already has the key and only the Hub row/policies need repair.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Text("Hub: \(hub.hubNodeBaseURL.absoluteString). Admin token is read from macOS Keychain service `\(ReviewAccessHubClient.keychainService)` and is never persisted in this view.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            if let oneTimeCode {
                VStack(alignment: .leading, spacing: 8) {
                    Text("One-time code copied to clipboard")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                    Text(oneTimeCode)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(8)
                        .background(Color.green.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    HStack {
                        Button("Copy again") { copyToClipboard(oneTimeCode) }
                            .controlSize(.small)
                        Button("Dismiss and clear") { self.oneTimeCode = nil }
                            .controlSize(.small)
                    }
                }
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        }
    }

    private var savedConfigsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Saved safe metadata", systemImage: "list.bullet.rectangle")
                .font(.headline)
            ForEach(reviewStore.configs) { config in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(config.accessLabel)
                            .font(.subheadline.weight(.medium))
                        Text(config.accessCodeID)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text("\(config.projectID) · \(config.policies.count) policies")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if let lastRotatedAt = config.lastRotatedAt {
                        Text(lastRotatedAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Replace") {
                        operationMode = .replaceExisting
                        selectedConfigID = config.id
                    }
                    .controlSize(.small)
                    Button(role: .destructive) { reviewStore.delete(config) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                }
                Divider()
            }
        }
    }

    private var debugDrawerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup(isExpanded: $debugDrawerExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Exact public payload fields are shown here for support. Admin token and raw access code values are always redacted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let debugLog {
                        HStack {
                            Button("Copy debug block") { copyToClipboard(debugLog) }
                                .controlSize(.small)
                            Text("Debug payload ready")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(debugLog)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        Text("No rotate payload has been prepared yet. Run a generate/replace action to populate the redacted debug block.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.top, 8)
            } label: {
                Label("Debug drawer", systemImage: "ladybug")
                    .font(.headline)
            }
        }
    }


    private var preflightSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Label("Hub preflight: \(preflightStatus.label)", systemImage: preflightStatusIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(preflightStatusColor)
                Button("Run preflight") { Task { await runPreflight() } }
                    .controlSize(.small)
                    .disabled(!canRunPreflight)
            }
            Text(preflightHelpText)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if case .rejected(let message) = preflightStatus, preflightFingerprint == currentPreflightFingerprint {
                Text("Hub rejected current payload: \(message)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.red)
            }
            if case .unavailable(let message) = preflightStatus, preflightFingerprint == currentPreflightFingerprint {
                Text("Preflight unavailable: \(message)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(preflightStatusColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var preflightHelpText: String {
        if preflightFingerprint != nil, preflightFingerprint != currentPreflightFingerprint {
            return "The payload changed after the last preflight; rerun preflight before relying on the server badge. Rotate is blocked only if Hub rejected the current payload."
        }
        switch preflightStatus {
        case .notRun:
            return "Validate the exact public rotate payload with Hub before generating or pasting a reviewer key. This writes nothing and never sends a raw code."
        case .running:
            return "Asking Hub to validate the exact public payload without persistence."
        case .accepted:
            return "Hub accepted the current payload. Final rotate will still use the same public fields plus the generated/provided reviewer key."
        case .rejected:
            return "Hub has rejected the current payload; fix the highlighted fields or reset canonical policies before rotating."
        case .unavailable:
            return "This Hub does not expose preflight yet or could not be reached. ZenithOS keeps graceful degradation and does not block rotate solely for unavailable preflight."
        }
    }

    private var preflightStatusIcon: String {
        switch preflightStatus {
        case .notRun: return "questionmark.circle"
        case .running: return "hourglass"
        case .accepted: return "checkmark.seal.fill"
        case .rejected: return "xmark.octagon.fill"
        case .unavailable: return "wifi.slash"
        }
    }

    private var preflightStatusColor: Color {
        switch preflightStatus {
        case .notRun: return .secondary
        case .running: return .blue
        case .accepted: return .green
        case .rejected: return .red
        case .unavailable: return .orange
        }
    }

    private var canRunPreflight: Bool {
        !isPreflighting && !isSubmitting && baseMetadataIsReady && policyValidationMessages.isEmpty && hub.reviewAccessAdminVerified
    }

    private var rotationSummary: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(effectiveOperationMode == .replaceExisting ? "Final target: replacing existing access record" : "Final target: creating new access record")
                .font(.caption.weight(.semibold))
            Text("Access row: \(targetAccessCodeID)")
                .font(.caption.weight(.semibold).monospaced())
            Text("Client: \(clientName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "—") (\(ReviewAccessCodeFactory.slug(from: clientSlug)))")
            Text("Access label: \(effectiveAccessLabel)")
            Text("Project: \(projectID.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "—")")
            Text("Policies: \(effectiveRotationPolicies.count)")
            ForEach(effectiveRotationPolicies) { policy in
                Text("policy[\(rotationPolicyIndex(policy))]: \(policy.label) · \(policy.deploymentID) · \(policy.allowedOrigin) → \(policy.subjectPattern)")
            }
        }
        .font(.caption2.monospaced())
        .foregroundStyle(.secondary)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(effectiveOperationMode == .replaceExisting ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var rotationReadinessSummary: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(canRotate ? "Ready to rotate" : "Not ready yet", systemImage: canRotate ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(canRotate ? .green : .orange)
            ForEach(rotationBlockers, id: \.self) { blocker in
                Text("• \(blocker)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if effectiveOperationMode == .replaceExisting, selectedConfigMismatches.isEmpty == false {
                Text("Metadata differences are shown for visibility only. Replacement preserves the selected access row and sends the final target above.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((canRotate ? Color.green : Color.orange).opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func clearSavedRecords() {
        reviewStore.deleteAll()
        selectedConfigID = nil
        operationMode = .createNew
        policies = normalizedRotationPolicies(policies, projectID: projectID)
        statusMessage = "Cleared saved Review Access metadata from this ZenithOS app. Hub records were not deleted."
    }

    private var canSave: Bool {
        !clientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !clientSlug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !projectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canRotate: Bool {
        rotationBlockers.isEmpty
    }

    private var baseMetadataIsReady: Bool {
        !clientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !clientSlug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !effectiveAccessLabel.isEmpty &&
        !projectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var rotationBlockers: [String] {
        var blockers: [String] = []
        if clientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blockers.append("Client name is required")
        }
        if clientSlug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blockers.append("Client slug is required")
        }
        if effectiveAccessLabel.isEmpty {
            blockers.append("Access label is required")
        }
        if projectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blockers.append("Project ID is required")
        }
        if !hub.reviewAccessAdminVerified {
            blockers.append("Verify Hub Connection")
        }
        if isSubmitting {
            blockers.append("Rotation request is already running")
        }
        if isPreflighting {
            blockers.append("Preflight request is still running")
        }
        if case .rejected(let message) = preflightStatus, preflightFingerprint == currentPreflightFingerprint {
            blockers.append("Hub preflight rejected current payload: \(message)")
        }
        blockers.append(contentsOf: policyValidationMessages)
        if effectiveOperationMode == .replaceExisting, selectedConfig == nil {
            blockers.append("Select an existing access record")
        }
        return blockers
    }

    private var effectiveOperationMode: ReviewAccessOperationMode {
        reviewStore.configs.isEmpty ? .createNew : operationMode
    }

    private var selectedContact: VaultContact? {
        guard let selectedContactID else { return nil }
        return hub.contacts.first { $0.id == selectedContactID }
    }

    private var selectedConfig: ReviewAccessConfig? {
        guard let selectedConfigID else { return nil }
        return reviewStore.configs.first { $0.id == selectedConfigID }
    }

    private var effectiveRotationPolicies: [ReviewAccessPolicy] {
        normalizedRotationPolicies(policies, projectID: projectID)
    }

    private var targetAccessCodeID: String {
        if effectiveOperationMode == .replaceExisting, let selectedConfig {
            return selectedConfig.accessCodeID
        }
        return ReviewAccessCodeFactory.accessCodeID(
            clientSlug: ReviewAccessCodeFactory.slug(from: clientSlug),
            projectID: projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private var effectiveAccessLabel: String {
        let trimmed = accessLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return clientName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var generateButtonTitle: String {
        switch effectiveOperationMode {
        case .replaceExisting:
            return "Replace code for \(clientName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "selected reviewer")"
        case .createNew:
            return "Generate new access code"
        }
    }

    private var providedCodeButtonTitle: String {
        switch effectiveOperationMode {
        case .replaceExisting:
            return "Replace with entered code"
        case .createNew:
            return "Create with entered code"
        }
    }

    private var selectedConfigMismatches: [String] {
        guard effectiveOperationMode == .replaceExisting, let selectedConfig else { return [] }
        var mismatches: [String] = []

        if clientName.trimmingCharacters(in: .whitespacesAndNewlines) != selectedConfig.clientName {
            mismatches.append("Client name differs: selected target uses \(selectedConfig.clientName)")
        }
        if ReviewAccessCodeFactory.slug(from: clientSlug) != selectedConfig.clientSlug {
            mismatches.append("Client slug differs: selected target uses \(selectedConfig.clientSlug)")
        }
        if effectiveAccessLabel != selectedConfig.accessLabel {
            mismatches.append("Access label differs: selected target uses \(selectedConfig.accessLabel)")
        }
        if projectID.trimmingCharacters(in: .whitespacesAndNewlines) != selectedConfig.projectID {
            mismatches.append("Project ID differs: selected target uses \(selectedConfig.projectID)")
        }
        if normalizedPolicies(policies) != normalizedPolicies(selectedConfig.policies) {
            mismatches.append("Allowed policies differ: selected target has \(selectedConfig.policies.count) policies")
        }

        return mismatches
    }

    private var hasBlockingMetadataMismatch: Bool {
        !selectedConfigMismatches.isEmpty && !allowEditedReplacementMetadata
    }

    private var policyValidationMessages: [String] {
        var messages: [String] = []
        if policies.isEmpty {
            messages.append("At least one allowed environment policy is required")
        }
        var seen = Set<String>()
        for policy in policies {
            let label = policy.label.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Policy"
            let deploymentID = policy.deploymentID.trimmingCharacters(in: .whitespacesAndNewlines)
            let origin = policy.allowedOrigin.trimmingCharacters(in: .whitespacesAndNewlines)
            let subject = policy.subjectPattern.trimmingCharacters(in: .whitespacesAndNewlines)
            if deploymentID.isEmpty { messages.append("\(label): deployment ID is required") }
            if origin.isEmpty { messages.append("\(label): allowed origin is required") }
            if subject.isEmpty { messages.append("\(label): subject pattern is required") }
            let isLocalAnyPortOrigin = ["http://localhost:*", "https://localhost:*", "http://127.0.0.1:*", "https://127.0.0.1:*"].contains(origin)
            if isLocalAnyPortOrigin {
                if !subject.hasPrefix(origin) {
                    messages.append("\(label): subject pattern origin must match allowed origin")
                }
            } else if !origin.isEmpty, let originURL = URL(string: origin) {
                if originURL.scheme == nil || originURL.host == nil || !["", "/"].contains(originURL.path) {
                    messages.append("\(label): allowed origin must be an origin, not a path")
                }
                let host = originURL.host?.lowercased() ?? ""
                if !["localhost", "127.0.0.1", "::1"].contains(host), originURL.scheme?.lowercased() != "https" {
                    messages.append("\(label): non-local origins must use HTTPS")
                }
                let subjectBase = subject.components(separatedBy: "*").first ?? subject
                if let subjectURL = URL(string: subjectBase), subjectURL.scheme != nil, subjectURL.host != nil {
                    if subjectURL.scheme?.lowercased() != originURL.scheme?.lowercased() || subjectURL.host?.lowercased() != originURL.host?.lowercased() || subjectURL.port != originURL.port {
                        messages.append("\(label): subject pattern origin must match allowed origin")
                    }
                }
            }
            let key = [deploymentID, origin, subject].joined(separator: "\u{1f}")
            if seen.contains(key) {
                messages.append("\(label): duplicate deployment/origin/subject policy")
            }
            seen.insert(key)
        }
        messages.append(contentsOf: galleryPolicyValidationMessages(for: effectiveRotationPolicies, projectID: projectID))
        return messages
    }

    private var policiesAreValid: Bool { policyValidationMessages.isEmpty }

    private func rotationPolicyIndex(_ policy: ReviewAccessPolicy) -> Int {
        effectiveRotationPolicies.firstIndex { $0.id == policy.id } ?? 0
    }

    private func normalizeOperationMode() {
        if reviewStore.configs.isEmpty {
            operationMode = .createNew
            selectedConfigID = nil
        }
    }

    private func applyOperationModeChange() {
        if effectiveOperationMode == .createNew {
            selectedConfigID = nil
            statusMessage = "Creating a new access record from the current form."
        } else if selectedConfig == nil {
            statusMessage = "Select an existing access record before replacing a code."
        }
    }

    private func applySelectedContactDefaults() {
        guard effectiveOperationMode == .createNew else { return }
        guard let contact = selectedContact else { return }
        clientName = contact.displayName
        clientSlug = ReviewAccessCodeFactory.slug(from: contact.displayName)
        if accessLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            accessLabel = contact.displayName
        }
    }

    private func applySelectedConfigDefaults() {
        guard let selectedConfig else { return }
        operationMode = .replaceExisting
        applyConfigToForm(selectedConfig)
    }

    private func applyConfigToForm(_ config: ReviewAccessConfig) {
        selectedContactID = contactID(from: config.rolodexEntryPath)
        clientName = config.clientName
        clientSlug = config.clientSlug
        accessLabel = config.accessLabel
        projectID = config.projectID
        projectName = config.projectName
        policies = normalizedRotationPolicies(config.policies, projectID: config.projectID)
        allowEditedReplacementMetadata = false
        oneTimeCode = nil
        statusMessage = "Loaded safe metadata for \(config.accessCodeID)."
    }

    private func createNewRecordFromCurrentForm() {
        operationMode = .createNew
        selectedConfigID = nil
        allowEditedReplacementMetadata = false
        statusMessage = "Creating a new access record from the current form."
    }

    private func applyProjectPreset(_ preset: ReviewAccessProjectPreset) {
        selectedPreset = preset
        projectID = preset.projectID
        projectName = preset.projectName
        policies = preset.defaultPolicies
        if preset == .swrlWeb, accessLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            accessLabel = "Dan Admin"
        }
        allowEditedReplacementMetadata = false
        statusMessage = "Loaded \(preset.label) project defaults with \(preset.defaultPolicies.count) allowed environment policies."
    }

    private func resetToCanonicalPolicies() {
        let preset = ReviewAccessProjectPreset.allCases.first { $0.projectID == projectID.trimmingCharacters(in: .whitespacesAndNewlines) } ?? selectedPreset
        selectedPreset = preset
        projectID = preset.projectID
        projectName = preset.projectName
        policies = preset.defaultPolicies
        allowEditedReplacementMetadata = false
        let restoredRows = preset.defaultPolicies.map { $0.deploymentID }.joined(separator: ", ")
        statusMessage = "Reset to canonical policies for \(preset.label): \(restoredRows). Compatibility metadata now previews \(preset.defaultPolicies.first?.deploymentID ?? "project-scoped")."
    }

    private func addPolicy(_ template: ReviewAccessPolicyTemplate) {
        switch template {
        case .localhost:
            policies.append(ReviewAccessPolicy(
                label: "Local any port",
                deploymentID: "\(ReviewAccessCodeFactory.slug(from: projectID))-local",
                allowedOrigin: "http://localhost:*",
                subjectPattern: "http://localhost:*/*"
            ))
        case .custom:
            policies.append(ReviewAccessPolicy(
                label: "Custom",
                deploymentID: "",
                allowedOrigin: "",
                subjectPattern: ""
            ))
        }
    }

    private func duplicatePolicy(_ policy: ReviewAccessPolicy) {
        var duplicate = policy
        duplicate.id = UUID()
        duplicate.label = "\(policy.label) copy"
        policies.append(duplicate)
    }

    private func removePolicy(_ policy: ReviewAccessPolicy) {
        policies.removeAll { $0.id == policy.id }
    }

    private func policyIndex(_ policy: ReviewAccessPolicy) -> Int {
        policies.firstIndex { $0.id == policy.id } ?? 0
    }

    private func normalizedPolicies(_ value: [ReviewAccessPolicy]) -> [String] {
        value.map {
            [
                $0.deploymentID.trimmingCharacters(in: .whitespacesAndNewlines),
                $0.allowedOrigin.trimmingCharacters(in: .whitespacesAndNewlines),
                $0.subjectPattern.trimmingCharacters(in: .whitespacesAndNewlines)
            ].joined(separator: "\u{1f}")
        }.sorted()
    }

    private func galleryPolicyValidationMessages(for value: [ReviewAccessPolicy], projectID rawProjectID: String) -> [String] {
        let projectIdentifier = rawProjectID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard projectIdentifier == ReviewAccessProjectPreset.gallery.projectID else { return [] }
        let effective = normalizedRotationPolicies(value, projectID: projectIdentifier)
        let expected = normalizedPolicies(ReviewAccessProjectPreset.gallery.defaultPolicies)
        let actual = normalizedPolicies(effective)
        if actual != expected {
            return ["Gallery review access must rotate exactly the canonical gallery-production-apex, gallery-production-www, and gallery-local policies"]
        }
        return []
    }

    private func normalizedRotationPolicies(_ value: [ReviewAccessPolicy], projectID rawProjectID: String) -> [ReviewAccessPolicy] {
        let projectIdentifier = rawProjectID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPolicies = value.map { policy in
            ReviewAccessPolicy(
                id: policy.id,
                label: policy.label.trimmingCharacters(in: .whitespacesAndNewlines),
                deploymentID: policy.deploymentID.trimmingCharacters(in: .whitespacesAndNewlines),
                deploymentSlug: policy.deploymentSlug.trimmingCharacters(in: .whitespacesAndNewlines),
                allowedOrigin: policy.allowedOrigin.trimmingCharacters(in: .whitespacesAndNewlines),
                subjectPattern: policy.subjectPattern.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        let legacyGalleryPolicyIDs = Set(["gallery-dev", "gallery-prod", "gallery-local", "gallery-production", "gallery-production-apex", "gallery-production-www"])
        if projectIdentifier == ReviewAccessProjectPreset.gallery.projectID,
           trimmedPolicies.count == 1,
           legacyGalleryPolicyIDs.contains(trimmedPolicies[0].deploymentID) {
            return ReviewAccessProjectPreset.gallery.defaultPolicies
        }
        return ReviewAccessConfig.normalizedPolicies(trimmedPolicies, projectID: projectIdentifier)
    }


    private var currentPreflightFingerprint: String {
        let payload = reviewAccessPayload(mode: .generate, rawCode: nil)
        return preflightFingerprint(for: payload)
    }

    private func preflightFingerprint(for payload: ReviewAccessRotateRequest) -> String {
        var parts = [
            payload.clientID,
            payload.clientSlug,
            payload.clientName,
            payload.projectID,
            payload.projectSlug,
            payload.projectName,
            payload.deploymentID ?? "",
            payload.deploymentSlug ?? "",
            payload.allowedOrigin ?? "",
            payload.subjectPattern ?? "",
            payload.accessCodeID,
            payload.accessLabel,
            String(payload.deploymentScopedAccess)
        ]
        payload.policies.forEach { policy in
            parts.append(contentsOf: [policy.deploymentID, policy.deploymentSlug, policy.allowedOrigin, policy.subjectPattern])
        }
        return parts.joined(separator: "\u{1f}")
    }

    private func preflightPolicyKey(_ policy: ReviewAccessPolicy) -> String {
        [
            policy.deploymentID.trimmingCharacters(in: .whitespacesAndNewlines),
            policy.allowedOrigin.trimmingCharacters(in: .whitespacesAndNewlines),
            policy.subjectPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        ].joined(separator: "\u{1f}")
    }

    private func preflightPolicyKey(_ policy: ReviewAccessPreflightPolicy) -> String {
        [
            policy.deploymentID.trimmingCharacters(in: .whitespacesAndNewlines),
            policy.allowedOrigin.trimmingCharacters(in: .whitespacesAndNewlines),
            policy.subjectPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        ].joined(separator: "\u{1f}")
    }

    private func preflightServerAcceptance(for policy: ReviewAccessPolicy) -> Bool? {
        guard preflightFingerprint == currentPreflightFingerprint else { return nil }
        switch preflightStatus {
        case .accepted:
            return preflightPolicyKeys.contains(preflightPolicyKey(policy))
        case .rejected:
            return false
        case .notRun, .running, .unavailable:
            return nil
        }
    }

    private func runPreflight() async {
        guard canRunPreflight else {
            statusMessage = "Cannot run preflight yet: \(rotationBlockers.joined(separator: "; "))."
            return
        }
        let payload = reviewAccessPayload(mode: .generate, rawCode: nil)
        let fingerprint = preflightFingerprint(for: payload)
        let requestID = UUID().uuidString
        guard let adminToken = ReviewAccessHubClient.adminTokenFromKeychain()?.trimmingCharacters(in: .whitespacesAndNewlines), !adminToken.isEmpty else {
            preflightStatus = .rejected(ReviewAccessHubClientError.missingAdminToken.localizedDescription)
            preflightFingerprint = fingerprint
            statusMessage = ReviewAccessHubClientError.missingAdminToken.localizedDescription
            debugLog = debugLogHeader(requestID: requestID, endpoint: "/v1/admin/review-auth/access-codes/preflight", mode: .generate, payload: payload, adminToken: "")
                + "\npreflight_status=failure"
                + "\nerror_description=\(ReviewAccessHubClientError.missingAdminToken.localizedDescription)"
            return
        }
        preflightStatus = .running
        preflightFingerprint = fingerprint
        preflightPolicyKeys = []
        isPreflighting = true
        statusMessage = "Running Hub preflight without sending a raw reviewer key…"
        debugLog = debugLogHeader(requestID: requestID, endpoint: "/v1/admin/review-auth/access-codes/preflight", mode: .generate, payload: payload, adminToken: adminToken)
        defer { isPreflighting = false }

        do {
            let response = try await ReviewAccessHubClient(baseURL: hub.hubNodeBaseURL).preflight(payload, adminToken: adminToken)
            preflightPolicyKeys = Set(response.policies.map(preflightPolicyKey))
            preflightStatus = .accepted
            statusMessage = "Hub preflight accepted \(response.policyCount) policy row(s); no data was persisted."
            debugLog = debugLogHeader(requestID: requestID, endpoint: "/v1/admin/review-auth/access-codes/preflight", mode: .generate, payload: payload, adminToken: adminToken)
                + "\npreflight_status=success"
                + "\npreflight_client_id=\(response.clientID)"
                + "\npreflight_project_id=\(response.projectID)"
                + "\npreflight_access_code_id=\(response.accessCodeID)"
                + "\npreflight_policy_count=\(response.policyCount)"
                + "\npreflight_project_scoped_access=\(response.projectScopedAccess)"
                + "\npreflight_secrets_printed=\(response.secretsPrinted)"
        } catch ReviewAccessHubClientError.http(let status, let body) where status == 404 {
            let message = "HTTP 404: \(body)"
            preflightStatus = .unavailable(message)
            statusMessage = "Hub preflight endpoint unavailable; rotate can still proceed with local validation."
            debugLog = debugLogHeader(requestID: requestID, endpoint: "/v1/admin/review-auth/access-codes/preflight", mode: .generate, payload: payload, adminToken: adminToken)
                + "\npreflight_status=unavailable"
                + "\nerror_description=\(message)"
        } catch ReviewAccessHubClientError.http(let status, let body) {
            let message = "HTTP \(status): \(body)"
            preflightStatus = .rejected(message)
            statusMessage = "Hub preflight rejected the current payload."
            debugLog = debugLogHeader(requestID: requestID, endpoint: "/v1/admin/review-auth/access-codes/preflight", mode: .generate, payload: payload, adminToken: adminToken)
                + "\npreflight_status=failure"
                + "\nerror_description=\(message)"
        } catch {
            let message = error.localizedDescription
            preflightStatus = .rejected(message)
            statusMessage = "Hub preflight failed for the current payload."
            debugLog = debugLogHeader(requestID: requestID, endpoint: "/v1/admin/review-auth/access-codes/preflight", mode: .generate, payload: payload, adminToken: adminToken)
                + "\npreflight_status=failure"
                + "\nerror_description=\(message)"
        }
    }

    private func generateCode() async {
        await rotate(mode: .generate, rawCode: nil)
    }

    private func useManualCode() async {
        let code = manualCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        await rotate(mode: .provided, rawCode: code)
    }

    private func rotate(mode: ReviewAccessRotateRequest.Mode, rawCode: String?) async {
        guard canRotate else {
            statusMessage = rotationBlockers.isEmpty ? "Select or enter the required review-access metadata before rotating." : "Cannot rotate yet: \(rotationBlockers.joined(separator: "; "))."
            return
        }
        let payload = reviewAccessPayload(mode: mode, rawCode: rawCode)
        let requestID = UUID().uuidString
        guard let adminToken = ReviewAccessHubClient.adminTokenFromKeychain()?.trimmingCharacters(in: .whitespacesAndNewlines), !adminToken.isEmpty else {
            statusMessage = ReviewAccessHubClientError.missingAdminToken.localizedDescription
            debugLog = debugLogHeader(requestID: requestID, endpoint: "/v1/admin/review-auth/access-codes/rotate", mode: mode, payload: payload, adminToken: "")
                + "\nresponse_status=failure"
                + "\nerror_description=\(ReviewAccessHubClientError.missingAdminToken.localizedDescription)"
            return
        }
        debugLog = debugLogHeader(requestID: requestID, endpoint: "/v1/admin/review-auth/access-codes/rotate", mode: mode, payload: payload, adminToken: adminToken)
        isSubmitting = true
        statusMessage = "Rotating access code in Hub…"
        defer { isSubmitting = false }

        do {
            let response = try await ReviewAccessHubClient(baseURL: hub.hubNodeBaseURL).rotate(payload, adminToken: adminToken)
            debugLog = debugLogHeader(requestID: requestID, endpoint: "/v1/admin/review-auth/access-codes/rotate", mode: mode, payload: payload, adminToken: adminToken)
                + "\nresponse_status=success"
                + "\nresponse_client_id=\(response.clientID)"
                + "\nresponse_project_id=\(response.projectID)"
                + "\nresponse_deployment_id=\(response.deploymentID ?? "project-scoped")"
                + "\nresponse_access_code_id=\(response.accessCodeID)"
                + "\nresponse_raw_code_present=\(response.rawCodePresent)"
                + "\nresponse_policy_count=\(response.policyCount)"
                + "\npolicy_count=\(response.policyCount)"
                + "\nresponse_active=\(response.active)"
            persistSafeConfig(lastRotatedAt: response.lastRotatedAt ?? Date())
            if mode == .generate {
                guard let generated = response.rawCode, response.rawCodePresent else {
                    throw ReviewAccessHubClientError.rawCodeMissing
                }
                copyToClipboard(generated)
                oneTimeCode = generated
                statusMessage = "Hub generated and stored the hash. Raw code copied once; send it through a safe channel."
            } else if let rawCode {
                copyToClipboard(rawCode)
                oneTimeCode = rawCode
                manualCode = ""
                statusMessage = "Hub stored the provided code hash. Manual code copied once and cleared from the input."
            }
        } catch {
            statusMessage = error.localizedDescription
            debugLog = debugLogHeader(requestID: requestID, endpoint: "/v1/admin/review-auth/access-codes/rotate", mode: mode, payload: payload, adminToken: adminToken)
                + "\nresponse_status=failure"
                + "\nerror_description=\(error.localizedDescription)"
        }
    }

    private func reviewAccessPayload(mode: ReviewAccessRotateRequest.Mode, rawCode: String?) -> ReviewAccessRotateRequest {
        let slug = ReviewAccessCodeFactory.slug(from: clientSlug)
        let projectIdentifier = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        let rotationPolicies = normalizedRotationPolicies(policies, projectID: projectIdentifier)
        let policyPayloads = rotationPolicies.map { policy in
            ReviewAccessPolicyPayload(
                deploymentID: policy.deploymentID.trimmingCharacters(in: .whitespacesAndNewlines),
                deploymentSlug: policy.deploymentSlug.trimmingCharacters(in: .whitespacesAndNewlines),
                allowedOrigin: policy.allowedOrigin.trimmingCharacters(in: .whitespacesAndNewlines),
                subjectPattern: policy.subjectPattern.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        let compatibilityPolicy = policyPayloads.first
        return ReviewAccessRotateRequest(
            clientID: slug,
            clientSlug: slug,
            clientName: clientName.trimmingCharacters(in: .whitespacesAndNewlines),
            rolodexEntryPath: selectedContact.map { "rolodex://\($0.id)" },
            projectID: projectIdentifier,
            projectSlug: ReviewAccessCodeFactory.slug(from: projectIdentifier),
            projectName: projectName.trimmingCharacters(in: .whitespacesAndNewlines),
            deploymentID: compatibilityPolicy?.deploymentID,
            deploymentSlug: compatibilityPolicy?.deploymentSlug,
            allowedOrigin: compatibilityPolicy?.allowedOrigin,
            subjectPattern: compatibilityPolicy?.subjectPattern,
            policies: policyPayloads,
            accessCodeID: targetAccessCodeID,
            accessLabel: effectiveAccessLabel,
            mode: mode,
            accessCode: rawCode,
            deploymentScopedAccess: false
        )
    }

    private func persistSafeConfig(lastRotatedAt: Date?) {
        let slug = ReviewAccessCodeFactory.slug(from: clientSlug)
        let accessID = targetAccessCodeID
        let contactPath = selectedContact.map { "rolodex://\($0.id)" }
        let projectIdentifier = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        let rotationPolicies = normalizedRotationPolicies(policies, projectID: projectIdentifier)
        reviewStore.upsert(ReviewAccessConfig(
            clientID: slug,
            clientSlug: slug,
            clientName: clientName.trimmingCharacters(in: .whitespacesAndNewlines),
            rolodexEntryPath: contactPath,
            projectID: projectIdentifier,
            projectSlug: ReviewAccessCodeFactory.slug(from: projectIdentifier),
            projectName: projectName.trimmingCharacters(in: .whitespacesAndNewlines),
            policies: rotationPolicies,
            accessCodeID: accessID,
            accessLabel: effectiveAccessLabel,
            lastRotatedAt: lastRotatedAt,
            active: true
        ))
    }

    private func copyToClipboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func debugLogHeader(
        requestID: String,
        endpoint: String,
        mode: ReviewAccessRotateRequest.Mode,
        payload: ReviewAccessRotateRequest,
        adminToken token: String
    ) -> String {
        ReviewAccessDebugPayloadBuilder.debugLog(
            context: ReviewAccessDebugPayloadBuilder.Context(
                requestID: requestID,
                hubURL: hub.hubNodeBaseURL,
                endpoint: endpoint,
                keychainService: ReviewAccessHubClient.keychainService,
                keychainAccount: ReviewAccessHubClient.keychainAccount,
                adminTokenPresent: !token.isEmpty,
                operationMode: effectiveOperationMode.rawValue,
                mode: mode,
                selectedExistingRow: effectiveOperationMode == .replaceExisting && selectedConfig != nil,
                payload: payload
            )
        )
    }


    @ViewBuilder
    private func metadataSummary(for config: ReviewAccessConfig) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Access row: \(config.accessCodeID)")
            Text("Client: \(config.clientName) (\(config.clientSlug))")
            Text("Project: \(config.projectID)")
            Text("Policies: \(config.policies.count)")
            ForEach(config.policies) { policy in
                Text("policy[\(config.policies.firstIndex { $0.id == policy.id } ?? 0)]: \(policy.label) · \(policy.deploymentID) · \(policy.allowedOrigin) → \(policy.subjectPattern)")
            }
        }
        .font(.caption2.monospaced())
        .foregroundStyle(.secondary)
    }

    private func contactID(from rolodexEntryPath: String?) -> VaultContact.ID? {
        guard let rolodexEntryPath, rolodexEntryPath.hasPrefix("rolodex://") else { return nil }
        return String(rolodexEntryPath.dropFirst("rolodex://".count))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
