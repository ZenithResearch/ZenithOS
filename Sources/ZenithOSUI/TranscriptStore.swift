import AppKit
import Combine

// MARK: - Transcript entry

struct TranscriptEntry: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let filename: String
    let date: String
    let time: String
    let status: String
    let audioCount: Int
    let preview: String    // first few lines of transcript body
    let modified: Date
}

// MARK: - Store

@MainActor
final class TranscriptStore: ObservableObject {

    @Published private(set) var entries: [TranscriptEntry] = []
    @Published private(set) var isLoading = false

    private let dir = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("claude-hub/capture/transcripts", isDirectory: true)
    private var watcher: DispatchSourceFileSystemObject?

    init() {
        load()
        watchDirectory()
    }

    func load() {
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let loaded = await Self.scan(dir: self.dir)
            await MainActor.run {
                self.entries  = loaded
                self.isLoading = false
            }
        }
    }

    func open(_ entry: TranscriptEntry) {
        NSWorkspace.shared.open(entry.url)
    }

    func revealInFinder(_ entry: TranscriptEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
    }

    // MARK: - Scan

    private static func scan(dir: URL) async -> [TranscriptEntry] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        return files
            .filter { $0.pathExtension == "md" }
            .compactMap { url -> TranscriptEntry? in
                guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return parse(url: url, raw: raw, modified: modified)
            }
            .sorted { $0.modified > $1.modified }
    }

    private static func parse(url: URL, raw: String, modified: Date) -> TranscriptEntry {
        let lines = raw.components(separatedBy: "\n")

        func frontmatterValue(_ key: String) -> String {
            lines.first { $0.hasPrefix("\(key):") }?
                .dropFirst(key.count + 1)
                .trimmingCharacters(in: .whitespaces) ?? ""
        }

        let date     = frontmatterValue("date")
        let time     = frontmatterValue("time")
        let status   = frontmatterValue("status")
        let audioCount = lines.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- path:") }.count

        // First non-empty bold line as preview
        let preview = lines
            .filter { $0.hasPrefix("**") }
            .prefix(3)
            .joined(separator: " · ")

        return TranscriptEntry(
            url:        url,
            filename:   url.deletingPathExtension().lastPathComponent,
            date:       date,
            time:       time,
            status:     status,
            audioCount: audioCount,
            preview:    preview,
            modified:   modified
        )
    }

    // MARK: - File watcher

    private func watchDirectory() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = Darwin.open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename],
            queue: DispatchQueue.global()
        )
        src.setEventHandler { [weak self] in
            Task { @MainActor in self?.load() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }
}
