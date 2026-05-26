import Foundation

// MARK: - Segment

struct TranscriptSegment {
    let timestamp: TimeInterval   // seconds from call start
    let speaker: String           // "You" or the remote label
    let text: String
}

// MARK: - AudioFile

struct AudioFile {
    let url: URL
    let speaker: String     // "you" | "remote"
    let duration: Double
    var assetID: Int64 = 0  // filled in after DB insert
}

// MARK: - Writer

final class TranscriptWriter {

    /// Write transcript note, save audio assets to DB, link everything together.
    /// Returns the transcript file URL.
    @discardableResult
    static func write(
        segments: [TranscriptSegment],
        audioFiles: [AudioFile],
        callDate: Date,
        remoteLabel: String
    ) throws -> URL {
        let dir = VaultConfig.transcriptsDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: VaultConfig.audioDir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let slug = formatter.string(from: callDate)
        let transcriptFile = dir.appendingPathComponent("facetime-\(slug).md")

        let dateStr = String(ISO8601DateFormatter().string(from: callDate).prefix(10))
        let timeStr: String = {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            return f.string(from: callDate)
        }()
        let isoDate = ISO8601DateFormatter().string(from: callDate)
        let noteRelPath = "capture/transcripts/facetime-\(slug).md"

        // ── Register audio assets in DB ────────────────────────────────────
        var registeredAudio = audioFiles
        for i in registeredAudio.indices {
            let af = registeredAudio[i]
            let relPath = "assets/audio/\(af.url.lastPathComponent)"
            let id = AssetStore.shared.insert(Asset(
                type:            "audio",
                path:            relPath,
                createdAt:       isoDate,
                source:          "facetime",
                speaker:         af.speaker,
                status:          "transcribed",
                relatedNote:     noteRelPath,
                durationSeconds: af.duration
            ))
            registeredAudio[i].assetID = id
        }

        // ── Register transcript asset in DB ───────────────────────────────
        let transcriptID = AssetStore.shared.insert(Asset(
            type:      "transcript",
            path:      noteRelPath,
            createdAt: isoDate,
            source:    "facetime",
            status:    "unprocessed",
            relatedNote: noteRelPath
        ))

        // Link transcript ↔ each audio file
        for af in registeredAudio where af.assetID > 0 {
            AssetStore.shared.link(assetID: transcriptID, to: af.assetID)
        }

        // ── Write markdown note ───────────────────────────────────────────
        var lines: [String] = [
            "---",
            "type: transcript",
            "date: \(dateStr)",
            "time: \(timeStr)",
            "participants:",
            "  you: You",
            "  remote: \(remoteLabel)",
            "source: FaceTime",
            "status: unprocessed",
        ]

        // Embed audio links in frontmatter
        if !registeredAudio.isEmpty {
            lines.append("audio:")
            for af in registeredAudio {
                let rel = "assets/audio/\(af.url.lastPathComponent)"
                lines.append("  - path: \(rel)")
                lines.append("    speaker: \(af.speaker)")
                lines.append(String(format: "    duration: %.1f", af.duration))
            }
        }

        lines += [
            "---",
            "",
            "# FaceTime — \(dateStr) \(timeStr)",
            "",
        ]

        if !registeredAudio.isEmpty {
            lines.append("## Audio")
            for af in registeredAudio {
                let rel = "assets/audio/\(af.url.lastPathComponent)"
                lines.append("- [\(af.speaker)](\(rel)) — \(formatDuration(af.duration))")
            }
            lines.append("")
            lines.append("## Transcript")
            lines.append("")
        }

        let sorted = segments.sorted { $0.timestamp < $1.timestamp }
        for seg in sorted where !seg.text.isEmpty {
            lines.append("**\(seg.speaker)** `\(formatTime(seg.timestamp))` \(seg.text)")
            lines.append("")
        }

        try lines.joined(separator: "\n").write(to: transcriptFile, atomically: true, encoding: .utf8)
        return transcriptFile
    }

    // MARK: - Helpers

    private static func formatTime(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }
}
