import Testing
@testable import ZenithOSUI

@Suite("Matrix homeserver configuration")
struct MatrixHomeserverConfigurationTests {
    @Test("Production homeserver is the fallback default")
    func productionDefault() {
        #expect(MatrixHomeserverConfiguration.normalized(nil) == "https://synapse.zenith-research.ca")
        #expect(MatrixHomeserverConfiguration.normalized("") == "https://synapse.zenith-research.ca")
    }

    @Test("Explicit localhost development endpoint is accepted")
    func localhostDevelopmentEndpoint() {
        #expect(MatrixHomeserverConfiguration.normalized("http://localhost:8008") == "http://localhost:8008")
    }

    @Test("Trailing slashes are normalized")
    func trailingSlashesAreNormalized() {
        #expect(MatrixHomeserverConfiguration.normalized("https://synapse.zenith-research.ca///") == "https://synapse.zenith-research.ca")
        #expect(MatrixHomeserverConfiguration.normalized("http://localhost:8008/") == "http://localhost:8008")
    }

    @Test(
        "Unsafe homeserver values fall back to production",
        arguments: [
            "not a URL",
            "https://user:password@synapse.zenith-research.ca",
            "https://synapse.zenith-research.ca?next=elsewhere",
            "https://synapse.zenith-research.ca/#fragment",
            "http://synapse.zenith-research.ca",
            "http://example.com:8008",
            "ftp://localhost:8008",
            "https://synapse.zenith-research.ca/matrix",
        ]
    )
    func unsafeValuesFallBackToProduction(value: String) {
        #expect(MatrixHomeserverConfiguration.normalized(value) == "https://synapse.zenith-research.ca")
    }

    @Test("Endpoint labels distinguish production and local development")
    func endpointLabels() {
        #expect(MatrixHomeserverConfiguration.label(for: "https://synapse.zenith-research.ca") == "Production")
        #expect(MatrixHomeserverConfiguration.label(for: "http://localhost:8008") == "Local Development")
    }
}
