import Foundation

/// A vault note with `type: repo` that describes a local repository.
struct RepoNote: Identifiable, Hashable {
    let id:         String   // note filename stem
    let name:       String   // human-readable title
    let repoPath:   String   // local absolute path to the repo
    let devCommand: String   // e.g. "npm run dev"
    let devPort:    Int      // e.g. 5173
    let devType:    String?  // "vite" | "next" | nil (open decision)
    let remoteURL:  String?  // git remote, for display only

    var localURL: URL { URL(fileURLWithPath: repoPath) }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
}

/// Scans the vault's `notes/` directory for `type: repo` notes.
enum RepoScanner {

    static func repos(at vaultPath: String) -> [RepoNote] {
        let notesDir = URL(fileURLWithPath: vaultPath).appendingPathComponent("notes")
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: notesDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return items
            .filter { $0.pathExtension == "md" }
            .compactMap { parse($0) }
            .sorted { $0.name < $1.name }
    }

    // MARK: Private

    private static func parse(_ url: URL) -> RepoNote? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let fm = parseYAML(text) else { return nil }

        guard (fm["type"] as? String) == "repo",
              let repoPath   = fm["repo_path"]   as? String,
              let devCommand = fm["dev_command"]  as? String,
              let devPort    = fm["dev_port"]     as? Int
        else { return nil }

        let stem = url.deletingPathExtension().lastPathComponent
        let name = (fm["title"] as? String)
                    ?? stem.replacingOccurrences(of: "-", with: " ").capitalized

        return RepoNote(
            id:         stem,
            name:       name,
            repoPath:   repoPath,
            devCommand: devCommand,
            devPort:    devPort,
            devType:    fm["dev_type"]    as? String,
            remoteURL:  fm["url"]         as? String
        )
    }

    /// Minimal YAML front-matter parser (same pattern as VaultScanner).
    private static func parseYAML(_ text: String) -> [String: Any]? {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        var result: [String: Any] = [:]
        var inFrontMatter = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                if !inFrontMatter { inFrontMatter = true; continue }
                else { break }
            }
            guard inFrontMatter, let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[trimmed.startIndex..<colon])
                        .trimmingCharacters(in: .whitespaces)
            let raw = String(trimmed[trimmed.index(after: colon)...])
                        .trimmingCharacters(in: .whitespaces)

            // Attempt Int, then Bool, then String
            if let i = Int(raw)          { result[key] = i }
            else if raw == "true"        { result[key] = true }
            else if raw == "false"       { result[key] = false }
            else {
                // Strip surrounding quotes
                let unquoted = raw.hasPrefix("\"") && raw.hasSuffix("\"")
                    ? String(raw.dropFirst().dropLast()) : raw
                result[key] = unquoted
            }
        }
        return result.isEmpty ? nil : result
    }
}
