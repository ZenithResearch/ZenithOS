import Foundation

struct HubArtifactMount: Codable, Equatable, Identifiable {
    var id: String { "\(runtimePrefix)->\(localRoot)" }
    let runtimePrefix: String
    let localRoot: String
    let label: String

    var normalizedRuntimePrefix: String {
        Self.normalizeRuntimePrefix(runtimePrefix)
    }

    var normalizedLocalRootURL: URL {
        URL(fileURLWithPath: NSString(string: localRoot).expandingTildeInPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    var displayLabel: String {
        label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? normalizedRuntimePrefix : label
    }

    static let userDefaultsKey = "hubArtifactMountsJSON"

    static func load(from json: String = UserDefaults.standard.string(forKey: userDefaultsKey) ?? "[]") -> [HubArtifactMount] {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([HubArtifactMount].self, from: data) else {
            return []
        }
        return decoded.filter { !$0.normalizedRuntimePrefix.isEmpty && !$0.localRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    static func encode(_ mounts: [HubArtifactMount]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(mounts), let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    static func normalized(_ mounts: [HubArtifactMount]) -> [HubArtifactMount] {
        var seen = Set<String>()
        return mounts.compactMap { mount in
            let runtime = normalizeRuntimePrefix(mount.runtimePrefix)
            let local = mount.localRoot.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !runtime.isEmpty, !local.isEmpty else { return nil }
            let key = runtime.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return HubArtifactMount(runtimePrefix: runtime, localRoot: local, label: mount.label.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func normalizeRuntimePrefix(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.count > 1 && value.hasSuffix("/") {
            value.removeLast()
        }
        guard value.hasPrefix("/") else { return "" }
        return URL(fileURLWithPath: value).standardizedFileURL.path
    }
}

struct HubArtifactMountResolution: Equatable {
    let mount: HubArtifactMount
    let fileURL: URL

    var label: String { mount.displayLabel }
}

enum HubArtifactMountResolver {
    static func resolve(runtimePath rawPath: String, mounts: [HubArtifactMount]) -> HubArtifactMountResolution? {
        let expanded = rawPath.hasPrefix("~/")
            ? NSString(string: rawPath).expandingTildeInPath
            : rawPath
        guard expanded.hasPrefix("/") else { return nil }

        let runtimeURL = URL(fileURLWithPath: expanded).standardizedFileURL
        let runtimePath = runtimeURL.path

        let sortedMounts = mounts
            .filter { !$0.normalizedRuntimePrefix.isEmpty }
            .sorted { $0.normalizedRuntimePrefix.count > $1.normalizedRuntimePrefix.count }

        for mount in sortedMounts {
            let prefix = mount.normalizedRuntimePrefix
            guard runtimePath == prefix || runtimePath.hasPrefix(prefix + "/") else { continue }

            let suffix = String(runtimePath.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let root = mount.normalizedLocalRootURL
            let candidate = suffix.isEmpty ? root : root.appendingPathComponent(suffix)
            let standardized = candidate.resolvingSymlinksInPath().standardizedFileURL

            guard path(standardized.path, isUnder: root.path) else { continue }
            guard FileManager.default.fileExists(atPath: standardized.path) else { continue }
            return HubArtifactMountResolution(mount: mount, fileURL: standardized)
        }

        return nil
    }

    private static func path(_ child: String, isUnder parent: String) -> Bool {
        let normalizedParent = parent.hasSuffix("/") ? String(parent.dropLast()) : parent
        return child == normalizedParent || child.hasPrefix(normalizedParent + "/")
    }
}
