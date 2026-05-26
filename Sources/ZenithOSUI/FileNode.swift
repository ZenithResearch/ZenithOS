import Foundation

struct FileNode: Identifiable, Hashable {
    let url: URL
    var children: [FileNode]?   // nil = file leaf; [] or [...] = directory

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var isDirectory: Bool { children != nil }

    var systemImage: String {
        if isDirectory { return "folder" }
        switch url.pathExtension.lowercased() {
        case "md":              return "doc.text"
        case "wav", "mp3", "m4a", "aiff": return "waveform"
        case "json":            return "curlybraces"
        case "swift":           return "swift"
        case "sh", "zsh", "bash": return "terminal"
        case "db", "sqlite":    return "cylinder"
        case "png", "jpg", "jpeg", "gif": return "photo"
        default:                return "doc"
        }
    }

    static func == (lhs: FileNode, rhs: FileNode) -> Bool { lhs.url == rhs.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}
