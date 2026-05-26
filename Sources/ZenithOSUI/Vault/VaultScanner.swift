import Foundation

/// Scans a vault directory for Rolodex contacts.
///
/// A note qualifies as a contact if its YAML frontmatter has:
///   - `type: person`  OR
///   - `domain` contains "people" (and no other explicit non-person type)
///
/// `matrixIds` may be empty — callers use that to distinguish connected vs invite-able contacts.
enum VaultScanner {

    /// Directories to skip during the vault walk.
    private static let skipDirs: Set<String> = [
        "templates", "ops", "self", "archive", ".git", ".obsidian"
    ]

    // MARK: - Public API

    static func contacts(at vaultPath: String) -> [VaultContact] {
        let root = URL(fileURLWithPath: vaultPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: vaultPath) else { return [] }

        var results: [VaultContact] = []
        scanDirectory(root, vaultId: "local", into: &results)
        return results.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    // MARK: - Private

    private static func scanDirectory(_ dir: URL, vaultId: String, into results: inout [VaultContact]) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return }

        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDir {
                if !skipDirs.contains(entry.lastPathComponent) {
                    scanDirectory(entry, vaultId: vaultId, into: &results)
                }
                continue
            }
            guard entry.pathExtension == "md" else { continue }
            if let contact = contact(from: entry, vaultId: vaultId) {
                results.append(contact)
            }
        }
    }

    private static func contact(from url: URL, vaultId: String) -> VaultContact? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let fm = parseFrontmatter(text),
              isPerson(fm) else { return nil }

        let stem = url.deletingPathExtension().lastPathComponent
        let name = (fm["name"] as? String)
            ?? (fm["title"] as? String)
            ?? stem

        let matrixIds = extractMatrixIds(fm)
        let id = "\(vaultId)/\(stem)"
        return VaultContact(id: id, displayName: name, matrixIds: matrixIds)
    }

    // MARK: - Frontmatter parser

    private static func parseFrontmatter(_ text: String) -> [String: Any]? {
        // Must start with "---\n"
        guard text.hasPrefix("---\n") else { return nil }
        let afterOpen = text.dropFirst(4)
        guard let closeRange = afterOpen.range(of: "\n---") else { return nil }
        let yaml = String(afterOpen[..<closeRange.lowerBound])
        return parseYAML(yaml)
    }

    /// Minimal YAML parser — handles string scalars and simple lists.
    private static func parseYAML(_ yaml: String) -> [String: Any]? {
        var dict: [String: Any] = [:]
        let lines = yaml.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            guard !line.hasPrefix("#"), !line.trimmingCharacters(in: .whitespaces).isEmpty else {
                i += 1; continue
            }
            guard let colonIdx = line.firstIndex(of: ":") else { i += 1; continue }
            let key = line[..<colonIdx].trimmingCharacters(in: .whitespaces)
            let rest = line[line.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)

            if rest.isEmpty || rest == "" {
                // Could be a block list — collect "  - item" lines
                var listItems: [String] = []
                i += 1
                while i < lines.count {
                    let next = lines[i]
                    let trimmed = next.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("- ") {
                        listItems.append(String(trimmed.dropFirst(2)).trimmingCharacters(in: .init(charactersIn: "\"'")))
                        i += 1
                    } else {
                        break
                    }
                }
                dict[key] = listItems
                continue
            } else if rest.hasPrefix("[") {
                // Inline list: [a, b, c]
                let inner = rest.dropFirst().dropLast()
                let items = inner.components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: .init(charactersIn: "\"'")) }
                    .filter { !$0.isEmpty }
                dict[key] = items
            } else {
                dict[key] = rest.trimmingCharacters(in: .init(charactersIn: "\"'"))
            }
            i += 1
        }
        return dict.isEmpty ? nil : dict
    }

    // MARK: - Helpers

    private static func isPerson(_ fm: [String: Any]) -> Bool {
        let noteType = fm["type"] as? String
        if noteType == "person" { return true }
        // Notes with an explicit non-person type (note, moc, spec, etc.) are not contacts
        if let t = noteType, t != "person" { return false }
        // Fall through to domain check only when type is absent
        let domain = fm["domain"]
        if let list = domain as? [String] { return list.contains("people") }
        if let str = domain as? String { return str.contains("people") }
        return false
    }

    private static func extractMatrixIds(_ fm: [String: Any]) -> [String] {
        let raw = fm["matrix_id"] ?? fm["matrix_ids"] ?? fm["matrix"]
        if raw == nil { return [] }
        if let list = raw as? [String] {
            return list.filter { $0.hasPrefix("@") }
        }
        if let str = raw as? String {
            let v = str.trimmingCharacters(in: .init(charactersIn: "\"'"))
            return v.hasPrefix("@") ? [v] : []
        }
        return []
    }
}
