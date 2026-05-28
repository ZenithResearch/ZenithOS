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
}
