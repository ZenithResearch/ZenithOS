import Foundation

enum MatrixHomeserverConfiguration {
    static let userDefaultsKey = "matrixHomeserverURL"
    static let productionURL = "https://synapse.zenith-research.ca"
    static let localDevelopmentURL = "http://localhost:8008"

    static func normalized(_ rawValue: String?) -> String {
        guard let rawValue else { return productionURL }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.allSatisfy({ $0 == "/" }),
              scheme == "https" || (scheme == "http" && isLoopback(host))
        else {
            return productionURL
        }

        var normalizedComponents = URLComponents()
        normalizedComponents.scheme = scheme
        normalizedComponents.host = host
        normalizedComponents.port = components.port
        return normalizedComponents.string ?? productionURL
    }

    static func label(for endpoint: String) -> String {
        isLoopback(URLComponents(string: normalized(endpoint))?.host?.lowercased() ?? "")
            ? "Local Development"
            : "Production"
    }

    static func registrationDisabledMessage(for endpoint: String, serverMessage: String) -> String {
        if label(for: endpoint) == "Local Development" {
            return serverMessage + " Set MATRIX_ENABLE_REGISTRATION=true in your local Synapse configuration and restart the homeserver."
        }
        return serverMessage + " Account creation is disabled on the production homeserver. Contact a Zenith administrator for access."
    }

    private static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "::1" || host.hasPrefix("127.")
    }
}
