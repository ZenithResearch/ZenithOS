import Foundation

struct TodoItem: Identifiable {
    let id: String          // filename without extension
    let title: String
    let status: String      // "pending" | "done"
    let arena: [String]
    let filePath: URL
}

@MainActor
final class TodoStore: ObservableObject {
    @Published var todos: [TodoItem] = []
    @Published var isLoading = false

    private let vaultRoot: URL

    init(vaultRoot: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("claude-hub", isDirectory: true)) {
        self.vaultRoot = vaultRoot
    }

    func loadToday() async {
        isLoading = true
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        let dailyNote = vaultRoot.appendingPathComponent("notes/\(today).md")
        todos = await resolveTodos(from: dailyNote)
        isLoading = false
    }

    func toggle(_ item: TodoItem) async {
        let newStatus = item.status == "done" ? "pending" : "done"
        guard var content = try? String(contentsOf: item.filePath, encoding: .utf8) else { return }
        content = content.replacingOccurrences(
            of: "status: \(item.status)",
            with: "status: \(newStatus)"
        )
        try? content.write(to: item.filePath, atomically: true, encoding: .utf8)
        await loadToday()
    }

    // MARK: - Parsing

    private func resolveTodos(from dailyNote: URL) async -> [TodoItem] {
        guard let content = try? String(contentsOf: dailyNote, encoding: .utf8) else { return [] }
        let links = extractTodoLinks(from: content)
        return links.compactMap { link in
            let file = vaultRoot.appendingPathComponent("notes/\(link).md")
            return readTodoNote(at: file, link: link)
        }
    }

    private func extractTodoLinks(from content: String) -> [String] {
        // Find ## To Do's section, extract [[wiki-links]]
        var inSection = false
        var links: [String] = []
        for line in content.components(separatedBy: "\n") {
            if line.hasPrefix("## To Do") {
                inSection = true
                continue
            }
            if inSection && line.hasPrefix("## ") { break }
            if inSection {
                let matches = wikiLinks(in: line)
                links.append(contentsOf: matches)
            }
        }
        return links
    }

    private func wikiLinks(in line: String) -> [String] {
        var results: [String] = []
        var remaining = line
        while let open = remaining.range(of: "[["),
              let close = remaining.range(of: "]]", range: open.upperBound..<remaining.endIndex) {
            let link = String(remaining[open.upperBound..<close.lowerBound])
            if !link.isEmpty { results.append(link) }
            remaining = String(remaining[close.upperBound...])
        }
        return results
    }

    private func readTodoNote(at url: URL, link: String) -> TodoItem? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let status = frontmatterValue(for: "status", in: content) ?? "pending"
        let arenaRaw = frontmatterValue(for: "arena", in: content) ?? ""
        let arena = arenaRaw
            .trimmingCharacters(in: .init(charactersIn: "[]"))
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return TodoItem(id: link, title: link, status: status, arena: arena, filePath: url)
    }

    private func frontmatterValue(for key: String, in content: String) -> String? {
        let lines = content.components(separatedBy: "\n")
        var inFrontmatter = false
        var fmCount = 0
        for line in lines {
            if line == "---" {
                fmCount += 1
                inFrontmatter = fmCount == 1
                if fmCount == 2 { break }
                continue
            }
            if inFrontmatter && line.hasPrefix("\(key):") {
                return line
                    .dropFirst("\(key):".count)
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
