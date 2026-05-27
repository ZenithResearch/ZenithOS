import Foundation

/// The local ZenithOS access contract for a remote Hub.
///
/// The remote Hub remains the authority for case/artifact metadata. ZenithOS runs
/// locally, so it needs one local access root where remote Hub/runtime file trees
/// are mirrored or materialized. Namespace identity and file browsing should follow
/// that same local mirror root instead of drifting into a separate identity setting.
enum HubRemoteAccess {
    static let localRootUserDefaultsKey = "hubPathRoot"

    static let defaultMirrorableDirectories = [
        HubArtifactMount(runtimePrefix: "/data", localRoot: "", label: "Data")
    ]

    static func mappings(from json: String = UserDefaults.standard.string(forKey: HubArtifactMount.userDefaultsKey) ?? "[]") -> [HubArtifactMount] {
        let configured = HubArtifactMount.load(from: json)
        return configured.isEmpty ? defaultMirrorableDirectories : configured
    }

    static func selectedRoot(from rootPath: String = UserDefaults.standard.string(forKey: localRootUserDefaultsKey) ?? "") -> URL {
        let trimmed = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return FileStore.hubRoot }
        return URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    static func mappings(
        from json: String = UserDefaults.standard.string(forKey: HubArtifactMount.userDefaultsKey) ?? "[]",
        rootPath: String = UserDefaults.standard.string(forKey: localRootUserDefaultsKey) ?? ""
    ) -> [HubArtifactMount] {
        let hasSelectedRoot = !rootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return mappings(from: json).map { mapping in
            if !hasSelectedRoot && mapping.hasLocalRoot { return mapping }
            let root = selectedRoot(from: rootPath)
            let suffix = mapping.normalizedRuntimePrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let localRoot = suffix.isEmpty ? root.path : root.appendingPathComponent(suffix).path
            return HubArtifactMount(runtimePrefix: mapping.normalizedRuntimePrefix, localRoot: localRoot, label: mapping.label)
        }
    }

    static func configuredLocalMirrorRoot(
        from json: String = UserDefaults.standard.string(forKey: HubArtifactMount.userDefaultsKey) ?? "[]",
        rootPath: String = UserDefaults.standard.string(forKey: localRootUserDefaultsKey) ?? ""
    ) -> URL? {
        if !rootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return selectedRoot(from: rootPath)
        }
        if let mirror = inferredAttachmentRoot(from: mappings(from: json)) {
            return mirror
        }
        return selectedRoot(from: rootPath)
    }

    static func inferredAttachmentRoot(from mappings: [HubArtifactMount]) -> URL? {
        guard let mapping = mappings.first(where: { $0.hasLocalRoot }) else { return nil }
        var root = mapping.normalizedLocalRootURL
        let suffixComponents = mapping.normalizedRuntimePrefix
            .split(separator: "/")
            .map(String.init)
        for component in suffixComponents.reversed() where root.lastPathComponent == component {
            root.deleteLastPathComponent()
        }
        return root
    }

    static func localMirrorRoot(
        from json: String = UserDefaults.standard.string(forKey: HubArtifactMount.userDefaultsKey) ?? "[]",
        rootPath: String = UserDefaults.standard.string(forKey: localRootUserDefaultsKey) ?? ""
    ) -> URL {
        if let mirror = configuredLocalMirrorRoot(from: json, rootPath: rootPath) {
            return mirror
        }
        return FileStore.hubRoot
    }

    static func namespace(
        from json: String = UserDefaults.standard.string(forKey: HubArtifactMount.userDefaultsKey) ?? "[]",
        rootPath: String = UserDefaults.standard.string(forKey: localRootUserDefaultsKey) ?? ""
    ) -> String {
        if let root = configuredLocalMirrorRoot(from: json, rootPath: rootPath),
           let namespace = HubStore.sanitizedNamespace(from: root.lastPathComponent) {
            return namespace
        }
        if let firstDirectory = mappings(from: json).first?.normalizedRuntimePrefix,
           let namespace = HubStore.sanitizedNamespace(from: URL(fileURLWithPath: firstDirectory).lastPathComponent) {
            return namespace
        }
        return "hub"
    }

    static func routeDescription(from json: String = UserDefaults.standard.string(forKey: HubArtifactMount.userDefaultsKey) ?? "[]") -> String {
        let directories = mappings(from: json)
            .map(\.normalizedRuntimePrefix)
            .sorted()
            .joined(separator: ", ")
        return directories.isEmpty ? "none" : directories
    }
}
