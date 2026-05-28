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
              "preview": ""
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
        #expect(decoded.providerSecretWrites?.supported == false)
    }
}
