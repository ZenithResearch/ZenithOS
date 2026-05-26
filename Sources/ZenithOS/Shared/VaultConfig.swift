import Foundation

enum VaultConfig {
    /// Root of the ZenithOS/personal hub vault on this machine.
    static let hubRoot = URL(fileURLWithPath: "/Users/bananawalnut/claude-hub")

    /// Capture inbox for FaceTime transcripts — picked up by /extract during sessions.
    static let transcriptsDir = hubRoot
        .appendingPathComponent("capture/transcripts", isDirectory: true)

    /// Persistent assets directory — audio files, attachments, etc.
    static let assetsDir = hubRoot
        .appendingPathComponent("assets", isDirectory: true)

    /// Raw audio recordings from calls.
    static let audioDir = assetsDir
        .appendingPathComponent("audio", isDirectory: true)

    /// SQLite asset index — path string for SQLite3 C API.
    static let dbPath = assetsDir.appendingPathComponent("assets.db").path
}
