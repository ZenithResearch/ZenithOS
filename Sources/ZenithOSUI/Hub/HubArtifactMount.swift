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
        Self.normalizeLocalRootURL(localRoot)
    }

    var hasLocalRoot: Bool {
        !Self.unescapeSlashedPath(localRoot).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var displayLabel: String {
        label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? normalizedRuntimePrefix : label
    }

    static let userDefaultsKey = "hubArtifactMountsJSON"

    static func primaryHubPathRoot(from mounts: [HubArtifactMount]) -> URL? {
        normalized(mounts).first(where: { $0.hasLocalRoot })?.normalizedLocalRootURL
    }

    static func normalizeLocalRootURL(_ raw: String) -> URL {
        URL(fileURLWithPath: NSString(string: unescapeSlashedPath(raw).trimmingCharacters(in: .whitespacesAndNewlines)).expandingTildeInPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    static func load(from json: String = UserDefaults.standard.string(forKey: userDefaultsKey) ?? "[]") -> [HubArtifactMount] {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([HubArtifactMount].self, from: data) else {
            return []
        }
        return normalized(decoded)
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
            var runtime = normalizeRuntimePrefix(mount.runtimePrefix)
            var local = unescapeSlashedPath(mount.localRoot).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !runtime.isEmpty else { return nil }
            if runtime == "/" {
                runtime = "/data"
                if !local.isEmpty {
                    local = normalizeLocalRootURL(local).appendingPathComponent("data").path
                }
            }
            let key = runtime.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return HubArtifactMount(runtimePrefix: runtime, localRoot: local, label: mount.label.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func normalizeRuntimePrefix(_ raw: String) -> String {
        var value = unescapeSlashedPath(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        while value.count > 1 && value.hasSuffix("/") {
            value.removeLast()
        }
        if !value.hasPrefix("/"), value.hasPrefix("data/") {
            value = "/" + value
        }
        guard value.hasPrefix("/") else { return "" }
        return URL(fileURLWithPath: value).standardizedFileURL.path
    }

    private static func unescapeSlashedPath(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\/", with: "/")
    }
}

struct HubArtifactMountResolution: Equatable {
    let mount: HubArtifactMount
    let fileURL: URL

    var label: String { mount.displayLabel }
}

enum HubArtifactMountResolver {
    static func resolve(runtimePath rawPath: String, mounts: [HubArtifactMount]) -> HubArtifactMountResolution? {
        guard let candidate = candidate(runtimePath: rawPath, mounts: mounts) else { return nil }
        guard FileManager.default.fileExists(atPath: candidate.fileURL.path) else { return nil }
        return candidate
    }

    static func candidate(runtimePath rawPath: String, mounts: [HubArtifactMount]) -> HubArtifactMountResolution? {
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
            guard mount.hasLocalRoot else { continue }
            guard prefix == "/" || runtimePath == prefix || runtimePath.hasPrefix(prefix + "/") else { continue }

            let suffix = prefix == "/"
                ? runtimePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                : String(runtimePath.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let root = mount.normalizedLocalRootURL
            let candidate = suffix.isEmpty ? root : root.appendingPathComponent(suffix)
            let standardized = candidate.resolvingSymlinksInPath().standardizedFileURL

            guard path(standardized.path, isUnder: root.path) else { continue }
            return HubArtifactMountResolution(mount: mount, fileURL: standardized)
        }

        return nil
    }

    static func path(_ child: String, isUnder parent: String) -> Bool {
        let normalizedParent = parent.hasSuffix("/") ? String(parent.dropLast()) : parent
        return child == normalizedParent || child.hasPrefix(normalizedParent + "/")
    }
}
