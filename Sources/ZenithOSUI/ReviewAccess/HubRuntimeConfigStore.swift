import Foundation

@MainActor
final class HubRuntimeConfigStore: ObservableObject {
    @Published var query = ModelProfileQuery(agent: "frank", profile: "review_brief_compiler", deploymentProfile: "cloud-aws-prod")
    @Published private(set) var runtimeConfig: HubRuntimeConfigResponse?
    @Published private(set) var manifest: HubImageEnvManifestResponse?
    @Published private(set) var effectiveProfile: ModelProfileEffectiveResponse?
    @Published private(set) var connectivity: ModelProfileConnectivityResponse?
    @Published private(set) var sttValidation: HubConfigValidationResponse?
    @Published private(set) var lastSecretRotation: ProviderSecretRotationResponse?
    @Published var lastError: String?
    @Published var statusMessage: String?
    @Published var isLoading = false
    @Published var isSaving = false
    @Published var isRotatingSecret = false

    var elevenLabsSecretTarget: ProviderSecretWriteTarget? {
        runtimeConfig?.providerSecretWrites?.targets.first { $0.target == "elevenlabs-stt" }
    }

    var supportsElevenLabsSecretRotation: Bool {
        runtimeConfig?.providerSecretWrites?.supported == true && elevenLabsSecretTarget != nil
    }

    var providerSecretBackendDescription: String {
        elevenLabsSecretTarget?.backend ?? runtimeConfig?.providerSecretWrites?.backend ?? "aws_secrets_manager"
    }

    func refresh(using client: ReviewAccessHubClient) async {
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        do {
            async let runtime = client.runtimeConfigStatus()
            async let imageManifest = client.imageEnvManifest()
            async let profile = client.effectiveModelProfile(query)
            runtimeConfig = try await runtime
            manifest = try await imageManifest
            effectiveProfile = try await profile
            statusMessage = "Runtime config refreshed."
        } catch {
            lastError = safeMessage(for: error)
        }
    }

    func checkConnectivity(using client: ReviewAccessHubClient) async {
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        do {
            connectivity = try await client.checkModelProfileConnectivity(query)
            statusMessage = connectivity?.ok == true ? "Model profile connectivity check passed." : "Model profile connectivity check completed."
        } catch {
            lastError = safeMessage(for: error)
        }
    }

    func validateSTT(using client: ReviewAccessHubClient) async {
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        do {
            sttValidation = try await client.validateSTTConfig()
            statusMessage = sttValidation?.ok == true ? "STT config validation passed." : "STT config validation completed."
        } catch {
            lastError = safeMessage(for: error)
        }
    }

    func saveNonSecretBinding(using client: ReviewAccessHubClient, operatorID: String, draft: ModelProfileBindingUpdateRequest) async {
        isSaving = true
        lastError = nil
        defer { isSaving = false }
        do {
            let response = try await client.updateModelProfileBinding(query, operatorID: operatorID, payload: draft)
            if let effective = response.effective {
                effectiveProfile = effective
            } else {
                effectiveProfile = try await client.effectiveModelProfile(query)
            }
            connectivity = response.connectivity
            statusMessage = "Model profile override saved."
        } catch {
            lastError = safeMessage(for: error)
        }
    }

    func rotateElevenLabsSecret(using client: ReviewAccessHubClient, operatorID: String, rawValue: String) async {
        isRotatingSecret = true
        lastError = nil
        defer { isRotatingSecret = false }
        do {
            let normalized = try HubProviderSecretInputValidator.normalized(rawValue)
            let response = try await client.rotateProviderSecret(target: "elevenlabs-stt", rawValue: normalized, operatorID: operatorID)
            lastSecretRotation = response
            statusMessage = response.configured ? "ElevenLabs secret rotated through Hub." : "ElevenLabs secret rotation completed."
        } catch HubProviderSecretInputValidator.ValidationError.empty {
            lastError = "ElevenLabs token is required."
        } catch HubProviderSecretInputValidator.ValidationError.multiline {
            lastError = "ElevenLabs token must be single-line."
        } catch {
            lastError = safeMessage(for: error)
        }
    }

    private func safeMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
