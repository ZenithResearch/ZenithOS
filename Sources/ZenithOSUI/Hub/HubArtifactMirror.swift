import Foundation

struct HubArtifactMaterializationResult: Equatable {
    let data: Data
    let localURL: URL?
}

enum HubArtifactMirror {
    static func mirrorFileReference(
        runtimePath rawPath: String,
        baseURL: URL?,
        usesAdminArtifactAccess: Bool,
        mounts: [HubArtifactMount],
        previewKind: FilePreviewKind = .markdown,
        sourceLabel: String = "HubFS path"
    ) -> SlotFileReference? {
        guard let normalizedRuntimePath = HubFSPath.normalize(rawPath),
              HubFSPath.isHubFSPath(normalizedRuntimePath),
              let baseURL else { return nil }

        let encodedPath = HubFSPath.base64URLEncoded(normalizedRuntimePath)
        let contentPath = usesAdminArtifactAccess
            ? "v1/admin/fs/by-path/\(encodedPath)/content"
            : "fs/by-path/\(encodedPath)/content"
        let contentURL = appendPath(contentPath, to: baseURL)
        let materializationCandidate = HubArtifactMountResolver.candidate(runtimePath: normalizedRuntimePath, mounts: mounts)
        return SlotFileReference(
            rawValue: rawPath,
            url: nil,
            displayPath: normalizedRuntimePath,
            previewKind: previewKind,
            resolutionState: .hubArtifact,
            sourceLabel: sourceLabel,
            artifactID: nil,
            artifactContentPath: contentPath,
            artifactContentURL: contentURL,
            usesAdminArtifactAccess: usesAdminArtifactAccess,
            materializationURL: materializationCandidate?.fileURL,
            materializationSourceLabel: materializationCandidate?.label
        )
    }

    static func materializeIfPossible(reference: SlotFileReference) async throws -> HubArtifactMaterializationResult {
        let data = try await fetchArtifactData(reference: reference)
        guard let destination = reference.materializationURL else {
            return HubArtifactMaterializationResult(data: data, localURL: nil)
        }
        let written = try writeAtomically(data, to: destination)
        return HubArtifactMaterializationResult(data: data, localURL: written)
    }

    static func fetchArtifactData(reference: SlotFileReference) async throws -> Data {
        if reference.usesAdminArtifactAccess, let path = reference.artifactContentPath {
            let client = ReviewAccessHubClient(baseURL: adminBaseURL(for: reference))
            return try await client.adminData(path: path)
        }

        guard let url = reference.artifactContentURL else {
            throw HubArtifactMirrorError.missingContentURL
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ReviewAccessHubClientError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    static func adminBaseURL(for reference: SlotFileReference) -> URL {
        guard var url = reference.artifactContentURL,
              let path = reference.artifactContentPath else {
            return ReviewAccessHubClient.defaultHubURL
        }
        for _ in path.split(separator: "/") {
            url.deleteLastPathComponent()
        }
        return url
    }

    private static func writeAtomically(_ data: Data, to destination: URL) throws -> URL {
        let standardized = destination.resolvingSymlinksInPath().standardizedFileURL
        let directory = standardized.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let temporary = directory.appendingPathComponent(".\(standardized.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: standardized.path) {
            try FileManager.default.removeItem(at: standardized)
        }
        try FileManager.default.moveItem(at: temporary, to: standardized)
        return standardized
    }

    private static func appendPath(_ path: String, to baseURL: URL) -> URL {
        var url = baseURL
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        return url
    }
}

enum HubArtifactMirrorError: LocalizedError {
    case missingContentURL

    var errorDescription: String? {
        switch self {
        case .missingContentURL:
            return "Hub artifact content URL is not available for materialization."
        }
    }
}
