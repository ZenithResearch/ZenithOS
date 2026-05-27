import Foundation

private let skipNames: Set<String> = [
    ".git", ".DS_Store", "node_modules", ".obsidian",
    ".build", ".claude",
]

@MainActor
final class FileStore: ObservableObject {
    nonisolated static let hubRoot = URL(fileURLWithPath: "/Users/bananawalnut/hub").resolvingSymlinksInPath()

    @Published private(set) var rootNodes: [FileNode] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String? = nil
    @Published private(set) var root: URL

    init(root: URL = FileStore.effectiveHubRoot()) {
        self.root = root
        load()
    }

    func useEffectiveHubRoot(
        from mountsJSON: String = UserDefaults.standard.string(forKey: HubArtifactMount.userDefaultsKey) ?? "[]",
        rootPath: String = UserDefaults.standard.string(forKey: HubRemoteAccess.localRootUserDefaultsKey) ?? ""
    ) {
        let nextRoot = Self.effectiveHubRoot(mountsJSON: mountsJSON, rootPath: rootPath)
        guard nextRoot != root else { return }
        root = nextRoot
        load()
    }

    nonisolated static func effectiveHubRoot(
        mountsJSON: String = UserDefaults.standard.string(forKey: HubArtifactMount.userDefaultsKey) ?? "[]",
        rootPath: String = UserDefaults.standard.string(forKey: HubRemoteAccess.localRootUserDefaultsKey) ?? ""
    ) -> URL {
        HubRemoteAccess.localMirrorRoot(from: mountsJSON, rootPath: rootPath)
    }

    func load() {
        isLoading = true
        errorMessage = nil
        let scanRoot = root
        Task.detached(priority: .userInitiated) {
            var err: String? = nil
            let nodes = Self.scan(url: scanRoot, error: &err)
            let captured = err
            await MainActor.run {
                self.rootNodes = nodes
                self.errorMessage = captured
                self.isLoading = false
            }
        }
    }

    func node(for url: URL) -> FileNode? {
        Self.findNode(url: url.resolvingSymlinksInPath(), in: rootNodes)
    }

    // MARK: - Recursive scan

    nonisolated private static func scan(url: URL, error: inout String?) -> [FileNode] {
        // Resolve symlinks — FileManager can fail silently on symlink URLs
        let target = url.resolvingSymlinksInPath()
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: target,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: .skipsHiddenFiles
            )
        } catch let e {
            if error == nil { error = "\(target.path): \(e.localizedDescription)" }
            return []
        }

        return entries
            .filter { !skipNames.contains($0.lastPathComponent) }
            .compactMap { child -> FileNode? in
                let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir {
                    var unused: String? = nil
                    return FileNode(url: child, children: scan(url: child, error: &unused))
                } else {
                    return FileNode(url: child, children: nil)
                }
            }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    nonisolated private static func findNode(url: URL, in nodes: [FileNode]) -> FileNode? {
        for node in nodes {
            if node.url.resolvingSymlinksInPath() == url {
                return node
            }
            if let children = node.children,
               let match = findNode(url: url, in: children) {
                return match
            }
        }
        return nil
    }
}
