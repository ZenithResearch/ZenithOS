import Foundation
import Testing
@testable import ZenithOSUI

@Suite("Hub runtime config")
struct HubRuntimeConfigTests {
    @Test("Provider secret input rejects empty values")
    func providerSecretInputRejectsEmptyValues() throws {
        #expect(throws: HubProviderSecretInputValidator.ValidationError.empty) {
            try HubProviderSecretInputValidator.normalized("   \n  ")
        }
    }

    @Test("Provider secret input rejects multiline values")
    func providerSecretInputRejectsMultilineValues() throws {
        #expect(throws: HubProviderSecretInputValidator.ValidationError.multiline) {
            try HubProviderSecretInputValidator.normalized("abc\ndef")
        }
    }

    @Test("Provider secret input trims single line value")
    func providerSecretInputTrimsSingleLineValue() throws {
        let normalized = try HubProviderSecretInputValidator.normalized("  placeholder-value  ")
        #expect(normalized == "placeholder-value")
    }

    @Test("Image manifest decodes backend environment maps")
    func imageManifestDecodesBackendEnvironmentMaps() throws {
        let json = """
        {
          "services": [
            {
              "service": "gateway",
              "environment": {"MODEL_PROFILES_PATH":"terraform:gateway_model_profiles_path"},
              "secrets": {"REVIEW_ACCESS_ADMIN_TOKEN":{"configured":true,"source":"aws_secrets_manager"}}
            }
          ],
          "secrets_printed": false
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(HubImageEnvManifestResponse.self, from: json)

        #expect(decoded.services.count == 1)
        #expect(decoded.services[0].env == ["MODEL_PROFILES_PATH"])
        #expect(decoded.services[0].secrets == ["REVIEW_ACCESS_ADMIN_TOKEN"])
        #expect(decoded.secretsPrinted == false)
    }

    @Test("Runtime config decodes top-level secret status and write capabilities")
    func runtimeConfigDecodesTopLevelSecretStatusAndWriteCapabilities() throws {
        let json = """
        {
          "secrets": {
            "ELEVENLABS_API_KEY": {
              "configured": false,
              "source": "aws_secrets_manager",
              "service": "frank",
              "preview": "redacted"
            }
          },
          "provider_secret_writes": {"supported":false,"backend":"aws_secrets_manager","targets":[]},
          "secrets_printed": false
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(HubRuntimeConfigResponse.self, from: json)

        #expect(decoded.secrets.count == 1)
        #expect(decoded.secrets[0].key == "ELEVENLABS_API_KEY")
        #expect(decoded.secrets[0].service == "frank")
        #expect(decoded.secrets[0].configured == false)
        #expect(decoded.secrets[0].handlePreview == "redacted")
        #expect(decoded.providerSecretWrites?.supported == false)
    }

    @Test("Runtime config decodes supported ElevenLabs provider-secret target")
    func runtimeConfigDecodesSupportedElevenLabsProviderSecretTarget() throws {
        let json = """
        {
          "secrets": {
            "ELEVENLABS_API_KEY": {
              "configured": true,
              "source": "aws_secrets_manager",
              "service": "frank",
              "handle_preview": "handle-redacted"
            }
          },
          "provider_secret_writes": {
            "supported": true,
            "backend": "aws_secrets_manager",
            "targets": [
              {
                "target": "elevenlabs-stt",
                "label": "ElevenLabs STT API key",
                "endpoint": "/v1/admin/secrets/provider/elevenlabs-stt",
                "secret_key": "ELEVENLABS_API_KEY",
                "backend": "aws_secrets_manager",
                "handle_preview": "handle-redacted",
                "restart_required": true,
                "consumer_services": ["frank"],
                "status": "configured"
              }
            ]
          },
          "secrets_printed": false
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(HubRuntimeConfigResponse.self, from: json)
        let target = decoded.providerSecretWrites?.targets.first

        #expect(decoded.providerSecretWrites?.supported == true)
        #expect(target?.target == "elevenlabs-stt")
        #expect(target?.secretKey == "ELEVENLABS_API_KEY")
        #expect(target?.backend == "aws_secrets_manager")
        #expect(target?.restartRequired == true)
        #expect(target?.consumerServices == ["frank"])
        #expect(target?.status == "configured")
    }

    @Test("Effective model profile decodes flat Hub runtime fields")
    func effectiveModelProfileDecodesFlatRuntimeFields() throws {
        let json = """
        {
          "agent": "frank",
          "profile": "review_brief_compiler",
          "deployment_profile": "cloud-aws-prod",
          "provider": "hub-internal-openai-compatible",
          "endpoint_ref": "prod-llama-server",
          "endpoint": {"base_url":"http://llama/v1","visibility":"private"},
          "model": "Qwen3.5-9B-Q4_K_M.gguf",
          "temperature": 0.15,
          "max_tokens": 1536,
          "timeout_seconds": 30,
          "fallback_profile": "fallback_fast",
          "secret": {"configured":false,"ref":"none"},
          "secrets_printed": false
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ModelProfileEffectiveResponse.self, from: json)

        #expect(decoded.endpointRef == "prod-llama-server")
        #expect(decoded.runtime?.temperature == 0.15)
        #expect(decoded.runtime?.maxTokens == 1536)
        #expect(decoded.runtime?.timeout == 30)
    }

    @Test("Model profile override encodes Hub update envelope")
    func modelProfileOverrideEncodesHubUpdateEnvelope() throws {
        let request = ModelProfileBindingUpdateRequest(
            provider: "hub-internal-openai-compatible",
            model: "Qwen3.5-9B-Q4_K_M.gguf",
            endpointHandle: "prod-llama-server",
            fallbackProfile: "fallback_fast",
            runtime: ModelProfileRuntime(timeout: 30, temperature: 0.15, maxTokens: 1536, enabled: true),
            enabled: true
        )

        let data = try JSONEncoder().encode(request)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let updates = object?["updates"] as? [String: Any]

        #expect(updates?["provider"] as? String == "hub-internal-openai-compatible")
        #expect(updates?["endpoint_ref"] as? String == "prod-llama-server")
        #expect(updates?["timeout_seconds"] as? Double == 30)
        #expect(updates?["temperature"] as? Double == 0.15)
        #expect(updates?["max_tokens"] as? Int == 1536)
        #expect(updates?["enabled"] == nil)
    }

    @Test("Stale SWRL metadata normalizes to canonical production and local policies")
    func staleSWRLMetadataNormalizesToCanonicalPolicies() throws {
        let staleLocalID = "swrl" + "-local"
        let staleWildcard = "https://www.collectswirls.com" + "*"
        let policies = ReviewAccessConfig.normalizedPolicies([
            ReviewAccessPolicy(
                label: "Stale production",
                deploymentID: "swrl-web-production",
                allowedOrigin: "https://www.collectswirls.com",
                subjectPattern: staleWildcard
            ),
            ReviewAccessPolicy(
                label: "Stale local",
                deploymentID: staleLocalID,
                allowedOrigin: "http://localhost:*",
                subjectPattern: "http://localhost:*/*"
            )
        ], projectID: ReviewAccessProjectPreset.swrlWeb.projectID)

        #expect(policies.map(\.deploymentID) == ["swrl-web-production", "swrl-web-local"])
        #expect(policies.map(\.allowedOrigin) == ["https://www.collectswirls.com", "http://localhost:*"])
        #expect(policies.map(\.subjectPattern) == ["https://www.collectswirls.com/*", "http://localhost:*/*"])
    }

    @Test("Policy row status marks canonical, stale, invalid, and server badges")
    func policyRowStatusBadgesReflectValidationContract() throws {
        let canonical = ReviewAccessProjectPreset.swrlWeb.defaultPolicies[1]
        let canonicalStatus = PolicyRowStatusViewModel.build(
            policy: canonical,
            projectID: ReviewAccessProjectPreset.swrlWeb.projectID,
            canonicalPolicies: ReviewAccessProjectPreset.swrlWeb.defaultPolicies,
            serverAccepted: true
        )
        #expect(canonicalStatus.badges == [.canonical, .serverOK])
        #expect(canonicalStatus.isValid)

        let staleStatus = PolicyRowStatusViewModel.build(
            policy: ReviewAccessPolicy(
                label: "Stale local",
                deploymentID: "swrl" + "-local",
                allowedOrigin: "http://localhost:*",
                subjectPattern: "http://localhost:*/*"
            ),
            projectID: ReviewAccessProjectPreset.swrlWeb.projectID,
            canonicalPolicies: ReviewAccessProjectPreset.swrlWeb.defaultPolicies
        )
        #expect(staleStatus.badges.contains(.stale))
        #expect(staleStatus.errors.contains { $0.contains("Known stale policy") })

        let invalidStatus = PolicyRowStatusViewModel.build(
            policy: ReviewAccessPolicy(label: "Custom", deploymentID: "", allowedOrigin: "", subjectPattern: ""),
            projectID: "custom",
            canonicalPolicies: [],
            localErrors: ["Custom: deployment ID is required"],
            serverAccepted: false
        )
        #expect(invalidStatus.badges.contains(.edited))
        #expect(invalidStatus.badges.contains(.invalid))
        #expect(invalidStatus.badges.contains(.serverRejected))
        #expect(!invalidStatus.isValid)
    }

    @Test("Review Access preflight response decodes safe public policy preview")
    func reviewAccessPreflightResponseDecodesPolicyPreview() throws {
        let json = """
        {
          "ok": true,
          "client_id": "hermione-granger",
          "project_id": "swrl",
          "deployment_id": "swrl-web-production",
          "access_code_id": "hermione-granger-swrl-review",
          "access_label": "SWRL Admin",
          "project_scoped_access": true,
          "email_configured": false,
          "policy_count": 2,
          "policies": [
            {
              "deployment_id": "swrl-web-production",
              "deployment_slug": "swrl-web-production",
              "allowed_origin": "https://www.collectswirls.com",
              "subject_pattern": "https://www.collectswirls.com/*"
            },
            {
              "deployment_id": "swrl-web-local",
              "deployment_slug": "swrl-web-local",
              "allowed_origin": "http://localhost:*",
              "subject_pattern": "http://localhost:*/*"
            }
          ],
          "secrets_printed": false
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ReviewAccessPreflightResponse.self, from: json)

        #expect(decoded.ok)
        #expect(decoded.accessCodeID == "hermione-granger-swrl-review")
        #expect(decoded.policyCount == 2)
        #expect(decoded.policies.map(\.deploymentID) == ["swrl-web-production", "swrl-web-local"])
        #expect(decoded.policies[0].subjectPattern == "https://www.collectswirls.com/*")
        #expect(decoded.secretsPrinted == false)
    }
}
