import Foundation

struct ReviewAccessPolicy: Identifiable, Codable, Equatable {
    var id: UUID
    var label: String
    var deploymentID: String
    var deploymentSlug: String
    var allowedOrigin: String
    var subjectPattern: String

    init(
        id: UUID = UUID(),
        label: String,
        deploymentID: String,
        deploymentSlug: String? = nil,
        allowedOrigin: String,
        subjectPattern: String
    ) {
        self.id = id
        self.label = label
        self.deploymentID = deploymentID
        self.deploymentSlug = deploymentSlug ?? deploymentID
        self.allowedOrigin = allowedOrigin
        self.subjectPattern = subjectPattern
    }
}

enum ReviewAccessProjectPreset: String, CaseIterable, Identifiable {
    case swrlWeb
    case swrlUI
    case gallery

    var id: String { rawValue }

    var label: String {
        switch self {
        case .swrlWeb: return "SWRL Web"
        case .swrlUI: return "SWRL UI"
        case .gallery: return "Gallery"
        }
    }

    var projectID: String {
        switch self {
        case .swrlWeb: return "swrl"
        case .swrlUI: return "swrl-ui"
        case .gallery: return "gallery"
        }
    }

    var projectSlug: String { ReviewAccessCodeFactory.slug(from: projectID) }

    var projectName: String {
        switch self {
        case .swrlWeb: return "SWRL"
        case .swrlUI: return "SWRL UI"
        case .gallery: return "Gallery"
        }
    }

    var defaultPolicies: [ReviewAccessPolicy] {
        switch self {
        case .swrlWeb:
            return [
                ReviewAccessPolicy(
                    label: "Production www",
                    deploymentID: "swrl-web-production",
                    deploymentSlug: "swrl-web-production",
                    allowedOrigin: "https://www.collectswirls.com",
                    subjectPattern: "https://www.collectswirls.com/*"
                ),
                ReviewAccessPolicy(
                    label: "Local any port",
                    deploymentID: "swrl-web-local",
                    deploymentSlug: "swrl-web-local",
                    allowedOrigin: "http://localhost:*",
                    subjectPattern: "http://localhost:*/*"
                )
            ]
        case .swrlUI:
            return [
                ReviewAccessPolicy(
                    label: "Production",
                    deploymentID: "swrl-ui-production-alias",
                    deploymentSlug: "swrl-ui-production-alias",
                    allowedOrigin: "https://swrl-ui.vercel.app",
                    subjectPattern: "https://swrl-ui.vercel.app/*"
                )
            ]
        case .gallery:
            return [
                ReviewAccessPolicy(
                    label: "Production apex",
                    deploymentID: "gallery-production-apex",
                    deploymentSlug: "gallery-production-apex",
                    allowedOrigin: "https://gal-ler-y.com",
                    subjectPattern: "https://gal-ler-y.com/*"
                ),
                ReviewAccessPolicy(
                    label: "Production www",
                    deploymentID: "gallery-production-www",
                    deploymentSlug: "gallery-production-www",
                    allowedOrigin: "https://www.gal-ler-y.com",
                    subjectPattern: "https://www.gal-ler-y.com/*"
                ),
                ReviewAccessPolicy(
                    label: "Local dev",
                    deploymentID: "gallery-local",
                    deploymentSlug: "gallery-local",
                    allowedOrigin: "http://localhost:*",
                    subjectPattern: "http://localhost:*/*"
                )
            ]
        }
    }
}

struct ReviewAccessConfig: Identifiable, Codable, Equatable {
    var id: String { accessCodeID }
    var clientID: String
    var clientSlug: String
    var clientName: String
    var rolodexEntryPath: String?
    var projectID: String
    var projectSlug: String
    var projectName: String
    var policies: [ReviewAccessPolicy]
    var accessCodeID: String
    var accessLabel: String
    var lastRotatedAt: Date?
    var active: Bool

    var deploymentID: String? { policies.first?.deploymentID }
    var deploymentSlug: String? { policies.first?.deploymentSlug }
    var allowedOrigin: String? { policies.first?.allowedOrigin }
    var subjectPattern: String? { policies.first?.subjectPattern }

    static let swrlDefaults = ReviewAccessConfig(
        clientID: "",
        clientSlug: "",
        clientName: "",
        rolodexEntryPath: nil,
        projectID: ReviewAccessProjectPreset.swrlUI.projectID,
        projectSlug: ReviewAccessProjectPreset.swrlUI.projectSlug,
        projectName: ReviewAccessProjectPreset.swrlUI.projectName,
        policies: ReviewAccessProjectPreset.swrlUI.defaultPolicies,
        accessCodeID: "",
        accessLabel: "",
        lastRotatedAt: nil,
        active: true
    )

    enum CodingKeys: String, CodingKey {
        case clientID
        case clientSlug
        case clientName
        case rolodexEntryPath
        case projectID
        case projectSlug
        case projectName
        case policies
        case deploymentID
        case deploymentSlug
        case allowedOrigin
        case subjectPattern
        case accessCodeID
        case accessLabel
        case lastRotatedAt
        case active
    }

    init(
        clientID: String,
        clientSlug: String,
        clientName: String,
        rolodexEntryPath: String?,
        projectID: String,
        projectSlug: String,
        projectName: String,
        policies: [ReviewAccessPolicy],
        accessCodeID: String,
        accessLabel: String,
        lastRotatedAt: Date?,
        active: Bool
    ) {
        self.clientID = clientID
        self.clientSlug = clientSlug
        self.clientName = clientName
        self.rolodexEntryPath = rolodexEntryPath
        self.projectID = projectID
        self.projectSlug = projectSlug
        self.projectName = projectName
        self.policies = policies
        self.accessCodeID = accessCodeID
        self.accessLabel = accessLabel
        self.lastRotatedAt = lastRotatedAt
        self.active = active
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clientID = try container.decode(String.self, forKey: .clientID)
        clientSlug = try container.decode(String.self, forKey: .clientSlug)
        clientName = try container.decode(String.self, forKey: .clientName)
        rolodexEntryPath = try container.decodeIfPresent(String.self, forKey: .rolodexEntryPath)
        projectID = try container.decode(String.self, forKey: .projectID)
        projectSlug = try container.decode(String.self, forKey: .projectSlug)
        projectName = try container.decode(String.self, forKey: .projectName)
        accessCodeID = try container.decode(String.self, forKey: .accessCodeID)
        accessLabel = try container.decode(String.self, forKey: .accessLabel)
        lastRotatedAt = try container.decodeIfPresent(Date.self, forKey: .lastRotatedAt)
        active = try container.decodeIfPresent(Bool.self, forKey: .active) ?? true

        let decodedPolicies: [ReviewAccessPolicy]
        if let storedPolicies = try container.decodeIfPresent([ReviewAccessPolicy].self, forKey: .policies), !storedPolicies.isEmpty {
            decodedPolicies = storedPolicies
        } else {
            decodedPolicies = ReviewAccessConfig.legacyPolicy(from: container)
        }
        policies = ReviewAccessConfig.normalizedPolicies(decodedPolicies, projectID: projectID)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(clientID, forKey: .clientID)
        try container.encode(clientSlug, forKey: .clientSlug)
        try container.encode(clientName, forKey: .clientName)
        try container.encodeIfPresent(rolodexEntryPath, forKey: .rolodexEntryPath)
        try container.encode(projectID, forKey: .projectID)
        try container.encode(projectSlug, forKey: .projectSlug)
        try container.encode(projectName, forKey: .projectName)
        try container.encode(policies, forKey: .policies)
        try container.encode(accessCodeID, forKey: .accessCodeID)
        try container.encode(accessLabel, forKey: .accessLabel)
        try container.encodeIfPresent(lastRotatedAt, forKey: .lastRotatedAt)
        try container.encode(active, forKey: .active)
    }

    private static func legacyPolicy(from container: KeyedDecodingContainer<CodingKeys>) -> [ReviewAccessPolicy] {
        let deploymentID = (try? container.decodeIfPresent(String.self, forKey: .deploymentID)) ?? nil
        let deploymentSlug = (try? container.decodeIfPresent(String.self, forKey: .deploymentSlug)) ?? deploymentID
        let allowedOrigin = (try? container.decodeIfPresent(String.self, forKey: .allowedOrigin)) ?? nil
        let subjectPattern = (try? container.decodeIfPresent(String.self, forKey: .subjectPattern)) ?? nil
        guard
            let deploymentID,
            let allowedOrigin,
            let subjectPattern,
            !deploymentID.isEmpty,
            !allowedOrigin.isEmpty,
            !subjectPattern.isEmpty
        else { return [] }
        return [
            ReviewAccessPolicy(
                label: "Legacy policy",
                deploymentID: deploymentID,
                deploymentSlug: deploymentSlug,
                allowedOrigin: allowedOrigin,
                subjectPattern: subjectPattern
            )
        ]
    }
    static func normalizedPolicies(_ policies: [ReviewAccessPolicy], projectID: String) -> [ReviewAccessPolicy] {
        guard projectID == ReviewAccessProjectPreset.gallery.projectID else { return policies }
        // Hub now rejects any Gallery rotation that is not the exact canonical
        // apex + www + local policy set. Decode-time normalization should
        // therefore discard stale local Gallery policy metadata rather than
        // resurfacing old two-policy or gallery-dev/gallery-prod records.
        return ReviewAccessProjectPreset.gallery.defaultPolicies
    }
}

enum ReviewAccessCodeFactory {
    static func generate() -> String {
        let bytes = (0..<32).map { _ in UInt8.random(in: UInt8.min...UInt8.max) }
        return Data(bytes).base64EncodedString()
    }

    static func slug(from raw: String) -> String {
        var output = ""
        var lastWasSeparator = true
        for scalar in raw.lowercased().unicodeScalars {
            switch scalar.value {
            case 97...122, 48...57:
                output.unicodeScalars.append(scalar)
                lastWasSeparator = false
            default:
                if !lastWasSeparator {
                    output.append("-")
                    lastWasSeparator = true
                }
            }
        }
        while output.last == "-" { output.removeLast() }
        return output.isEmpty ? "reviewer" : output
    }

    static func accessCodeID(clientSlug: String, projectID: String) -> String {
        "\(clientSlug)-\(slug(from: projectID))-review"
    }

    static func swrlAccessCodeID(clientSlug: String) -> String {
        accessCodeID(clientSlug: clientSlug, projectID: ReviewAccessConfig.swrlDefaults.projectID)
    }
}
