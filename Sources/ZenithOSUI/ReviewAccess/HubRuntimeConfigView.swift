import SwiftUI

struct HubRuntimeConfigView: View {
    @ObservedObject var store: HubRuntimeConfigStore
    let hubBaseURL: URL

    @State private var operatorID = NSUserName().isEmpty ? "zenithos-local-operator" : NSUserName()
    @State private var providerDraft = ""
    @State private var modelDraft = ""
    @State private var endpointHandleDraft = ""
    @State private var fallbackProfileDraft = ""
    @State private var timeoutDraft = ""
    @State private var temperatureDraft = ""
    @State private var maxTokensDraft = ""
    @State private var elevenLabsTokenDraft = ""
    @State private var selectedManifestServiceID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            actionRow
            statusMessages
            manifestSummary
            secretStatusSection
            modelProfileSection
            elevenLabsSecretSection
        }
        .onChange(of: store.effectiveProfile?.model ?? "") { _ in loadDraftFromEffectiveProfile() }
        .onChange(of: store.manifest?.services.map(\.id).joined(separator: "|") ?? "") { _ in selectFirstManifestServiceIfNeeded() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Hub runtime config", systemImage: "server.rack")
                .font(.headline)
            Text("Inspect live Hub env/model/STT status and apply safe operator changes. Provider secrets are only accepted when Hub advertises a Secrets Manager-backed one-shot write target.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Active Hub: \(hubBaseURL.absoluteString)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Label(ReviewAccessHubClient.hasAdminTokenInKeychain() ? "Admin token configured in Keychain" : "Admin token missing from Keychain", systemImage: ReviewAccessHubClient.hasAdminTokenInKeychain() ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(ReviewAccessHubClient.hasAdminTokenInKeychain() ? .green : .orange)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button("Refresh status") { Task { await refresh() } }
                .disabled(store.isLoading)
            Button("Check Frank connectivity") { Task { await store.checkConnectivity(using: client) } }
                .disabled(store.isLoading)
            Button("Validate STT provider") { Task { await store.validateSTT(using: client) } }
                .disabled(store.isLoading)
            if store.isLoading || store.isSaving || store.isRotatingSecret {
                ProgressView().controlSize(.small)
            }
        }
        .controlSize(.small)
    }

    private var statusMessages: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let statusMessage = store.statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let lastError = store.lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let validation = store.sttValidation {
                statusPill(title: "STT", ok: validation.ok, detail: validation.detail ?? validation.status ?? validation.provider ?? "Validation response received")
            }
            if let connectivity = store.connectivity {
                let detail = connectivity.detail ?? connectivity.model ?? connectivity.endpoint ?? "Connectivity response received"
                statusPill(title: "Model", ok: connectivity.ok, detail: detail)
            }
        }
    }

    private var manifestSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Image/env manifest")
                    .font(.caption.weight(.semibold))
                Spacer()
                if let selectedManifestService {
                    Text("Selected: \(display(selectedManifestService.service))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            if let manifest = store.manifest {
                if manifest.services.isEmpty {
                    Text("No services returned by this Hub manifest.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(manifest.services.prefix(8)) { service in
                        manifestServiceRow(service)
                    }
                    if manifest.services.count > 8 {
                        Text("+ \(manifest.services.count - 8) more services")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    selectedManifestServiceDetail
                }
            } else {
                Text("Refresh to load image/env coverage from Hub.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func manifestServiceRow(_ service: HubImageEnvService) -> some View {
        Button {
            selectedManifestServiceID = service.id
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Text(service.service.isEmpty ? "unknown" : service.service)
                    .font(.caption.monospaced().weight(.medium))
                    .frame(width: 108, alignment: .leading)
                Text("env \(service.env.count) · secrets \(service.secrets.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: selectedManifestServiceID == service.id ? "checkmark.circle.fill" : "chevron.right.circle")
                    .font(.caption2)
                    .foregroundStyle(selectedManifestServiceID == service.id ? Color.accentColor : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var selectedManifestService: HubImageEnvService? {
        guard let services = store.manifest?.services, !services.isEmpty else { return nil }
        if let selectedManifestServiceID,
           let selected = services.first(where: { $0.id == selectedManifestServiceID }) {
            return selected
        }
        return services.first
    }

    @ViewBuilder
    private var selectedManifestServiceDetail: some View {
        if let service = selectedManifestService {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                Text("\(display(service.service)) contract")
                    .font(.caption.weight(.semibold))
                if let image = service.image, !image.isEmpty {
                    Text("Image: \(image)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                manifestKeyList(title: "Environment", keys: service.env, empty: "No environment variables declared for this service.")
                manifestKeyList(title: "Secrets", keys: service.secrets, empty: "No secret handles declared for this service.")
                if service.secrets.contains("ELEVENLABS_API_KEY") {
                    Text(store.supportsElevenLabsSecretRotation ? "This Hub advertises one-shot ElevenLabs rotation below." : "ELEVENLABS_API_KEY is status-only on this Hub until provider-secret writes are enabled.")
                        .font(.caption2)
                        .foregroundStyle(store.supportsElevenLabsSecretRotation ? .green : .secondary)
                }
            }
            .padding(.top, 2)
        }
    }

    private func manifestKeyList(title: String, keys: [String], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            if keys.isEmpty {
                Text(empty)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 4) {
                    ForEach(keys, id: \.self) { key in
                        Text(key)
                            .font(.caption2.monospaced())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var secretStatusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Runtime secrets")
                .font(.caption.weight(.semibold))
            if let runtimeConfig = store.runtimeConfig {
                let serviceSecrets = runtimeConfig.services.flatMap { service in
                    service.secrets.map { (service.service, $0) }
                }
                let topLevelSecrets = runtimeConfig.secrets.map { ($0.service ?? "runtime", $0) }
                let secrets = serviceSecrets + topLevelSecrets
                if secrets.isEmpty {
                    Text("No secret status rows returned. This Hub may only expose manifest-level status.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(secrets.prefix(10).enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .top, spacing: 8) {
                            Circle()
                                .fill((row.1.configured ?? false) ? Color.green : Color.orange)
                                .frame(width: 7, height: 7)
                                .padding(.top, 5)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(row.0.isEmpty ? "service" : row.0).\(row.1.key)")
                                    .font(.caption.monospaced())
                                Text(secretDetail(row.1))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                providerSecretCapabilitySummary(runtimeConfig.providerSecretWrites)
            } else {
                Text("Refresh to load secret status from Hub. Raw secret values are never displayed here.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var modelProfileSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Agent model profile")
                .font(.caption.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow { Text("Agent").foregroundStyle(.secondary); TextField("frank", text: $store.query.agent).textFieldStyle(.roundedBorder).font(.caption.monospaced()) }
                GridRow { Text("Profile").foregroundStyle(.secondary); TextField("review_brief_compiler", text: $store.query.profile).textFieldStyle(.roundedBorder).font(.caption.monospaced()) }
                GridRow { Text("Deployment").foregroundStyle(.secondary); TextField("cloud-aws-prod", text: $store.query.deploymentProfile).textFieldStyle(.roundedBorder).font(.caption.monospaced()) }
            }
            .font(.caption)

            if let effective = store.effectiveProfile {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Effective: \(display(effective.provider)) / \(display(effective.model))")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Text("Endpoint: \(display(effective.endpointRef ?? effective.endpoint?.handle ?? effective.endpoint?.baseURL)) · Fallback: \(display(effective.fallbackProfile))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            DisclosureGroup("Safe non-secret override") {
                VStack(alignment: .leading, spacing: 8) {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                        GridRow { Text("Provider").foregroundStyle(.secondary); TextField("provider", text: $providerDraft).textFieldStyle(.roundedBorder) }
                        GridRow { Text("Model").foregroundStyle(.secondary); TextField("model", text: $modelDraft).textFieldStyle(.roundedBorder) }
                        GridRow { Text("Endpoint handle").foregroundStyle(.secondary); TextField("endpoint-ref", text: $endpointHandleDraft).textFieldStyle(.roundedBorder) }
                        GridRow { Text("Fallback").foregroundStyle(.secondary); TextField("fallback_fast", text: $fallbackProfileDraft).textFieldStyle(.roundedBorder) }
                        GridRow { Text("Timeout").foregroundStyle(.secondary); TextField("seconds", text: $timeoutDraft).textFieldStyle(.roundedBorder) }
                        GridRow { Text("Temperature").foregroundStyle(.secondary); TextField("0.2", text: $temperatureDraft).textFieldStyle(.roundedBorder) }
                        GridRow { Text("Max tokens").foregroundStyle(.secondary); TextField("4096", text: $maxTokensDraft).textFieldStyle(.roundedBorder) }
                    }
                    .font(.caption)
                    HStack {
                        TextField("Operator ID", text: $operatorID)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption.monospaced())
                        Button("Load effective") { loadDraftFromEffectiveProfile() }
                        Button("Save non-secret override") { Task { await saveDraft() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(store.isSaving || operatorID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .controlSize(.small)
                    Text("This form intentionally has no API key, token, password, arbitrary env map, or raw secret-ref field.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 6)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var elevenLabsSecretSection: some View {
        if store.supportsElevenLabsSecretRotation {
            VStack(alignment: .leading, spacing: 10) {
                Label("Update ElevenLabs secret", systemImage: "key.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                Text("ZenithOS sends this token once to Hub at \(hubBaseURL.absoluteString), then clears the field. Hub must rotate the AWS Secrets Manager-backed value and return only safe status metadata.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("Target: \(store.elevenLabsSecretTarget?.target ?? "elevenlabs-stt") · Key: \(store.elevenLabsSecretTarget?.secretKey ?? "ELEVENLABS_API_KEY") · Backend: \(store.providerSecretBackendDescription)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                HStack {
                    SecureField("Paste ElevenLabs API key", text: $elevenLabsTokenDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                    Button("Rotate ElevenLabs secret") { submitElevenLabsSecret() }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.isRotatingSecret || elevenLabsTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Cancel and clear") { elevenLabsTokenDraft = "" }
                }
                .controlSize(.small)
                if let rotation = store.lastSecretRotation {
                    Text("Last rotation: configured=\(rotation.configured ? "yes" : "no") · backend=\(display(rotation.backend)) · handle=\(display(rotation.handlePreview))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.green)
                }
            }
            .padding(10)
            .background(Color.orange.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Provider secret writes are status-only on this Hub.")
                    .font(.caption.weight(.semibold))
                Text("When Hub advertises provider_secret_writes target `elevenlabs-stt`, ZenithOS will enable a one-shot token rotation field. Until then, rotate ELEVENLABS_API_KEY through AWS Secrets Manager or the deployment control plane.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private var client: ReviewAccessHubClient {
        ReviewAccessHubClient(baseURL: hubBaseURL)
    }

    private func refresh() async {
        await store.refresh(using: client)
        loadDraftFromEffectiveProfile()
    }

    private func saveDraft() async {
        let runtime = ModelProfileRuntime(
            timeout: Double(timeoutDraft.trimmingCharacters(in: .whitespacesAndNewlines)),
            temperature: Double(temperatureDraft.trimmingCharacters(in: .whitespacesAndNewlines)),
            maxTokens: Int(maxTokensDraft.trimmingCharacters(in: .whitespacesAndNewlines)),
            enabled: nil
        )
        let draft = ModelProfileBindingUpdateRequest(
            provider: optional(providerDraft),
            model: optional(modelDraft),
            endpointHandle: optional(endpointHandleDraft),
            fallbackProfile: optional(fallbackProfileDraft),
            runtime: runtime,
            enabled: nil
        )
        await store.saveNonSecretBinding(using: client, operatorID: operatorID, draft: draft)
        loadDraftFromEffectiveProfile()
    }

    private func submitElevenLabsSecret() {
        let raw = elevenLabsTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            store.lastError = "ElevenLabs token is required."
            return
        }
        guard !raw.contains("\n") && !raw.contains("\r") else {
            elevenLabsTokenDraft = ""
            store.lastError = "ElevenLabs token must be single-line."
            return
        }
        Task {
            defer { elevenLabsTokenDraft = "" }
            await store.rotateElevenLabsSecret(using: client, operatorID: operatorID, rawValue: raw)
            await store.refresh(using: client)
            await store.validateSTT(using: client)
        }
    }

    private func loadDraftFromEffectiveProfile() {
        guard let effective = store.effectiveProfile else { return }
        providerDraft = effective.provider ?? ""
        modelDraft = effective.model ?? ""
        endpointHandleDraft = effective.endpointRef ?? effective.endpoint?.handle ?? ""
        fallbackProfileDraft = effective.fallbackProfile ?? ""
        timeoutDraft = effective.runtime?.timeout.map { String($0) } ?? ""
        temperatureDraft = effective.runtime?.temperature.map { String($0) } ?? ""
        maxTokensDraft = effective.runtime?.maxTokens.map { String($0) } ?? ""
    }

    private func selectFirstManifestServiceIfNeeded() {
        guard let services = store.manifest?.services, !services.isEmpty else {
            selectedManifestServiceID = nil
            return
        }
        if let selectedManifestServiceID,
           services.contains(where: { $0.id == selectedManifestServiceID }) {
            return
        }
        selectedManifestServiceID = services.first?.id
    }

    private func statusPill(title: String, ok: Bool?, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
            Text(ok == true ? "ok" : "check")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(ok == true ? .green : .orange)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func providerSecretCapabilitySummary(_ capability: ProviderSecretWriteCapabilities?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Provider-secret writes: \(capability?.supported == true ? "supported" : "not supported")")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(capability?.supported == true ? .green : .secondary)
            Text("Backend: \(capability?.backend ?? "—") · Targets: \((capability?.targets.map { $0.target }.joined(separator: ", ")).flatMap { $0.isEmpty ? nil : $0 } ?? "none")")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    private func secretDetail(_ secret: HubRuntimeSecretStatus) -> String {
        let configured = (secret.configured ?? false) ? "configured" : "missing"
        return "\(configured) · source=\(secret.source ?? "—") · handle=\(secret.handlePreview ?? "redacted")"
    }

    private func optional(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func display(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "—" }
        return value
    }
}
