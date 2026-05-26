import Foundation
import SQLite3

// SQLITE_TRANSIENT is a C macro (-1 cast to destructor type) — not imported by Swift
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Asset model

struct Asset {
    var id: Int64 = 0
    var type: String          // "audio" | "transcript"
    var path: String          // relative to hub root
    var createdAt: String     // ISO8601
    var source: String        // "facetime"
    var speaker: String?      // "you" | "remote" | nil
    var status: String        // "raw" | "transcribed" | "failed" | "processed"
    var relatedNote: String?  // relative path to .md note
    var relatedAssetIDs: [Int64] = []  // linked asset IDs (e.g. transcript ↔ audio)
    var durationSeconds: Double?
    var summary: String?
}

// MARK: - AssetStore

/// SQLite-backed index for all vault assets (audio files, transcripts).
/// Thread-safe: all mutations go through a dedicated serial queue.
final class AssetStore {

    static let shared = AssetStore()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.zenith.assetstore", qos: .utility)

    private init() {
        queue.sync { self.open() }
    }

    // MARK: - Public API

    /// Insert a new asset. Returns the assigned row ID.
    @discardableResult
    func insert(_ asset: Asset) -> Int64 {
        var rowID: Int64 = 0
        queue.sync {
            let idsJSON = (try? JSONEncoder().encode(asset.relatedAssetIDs))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

            let sql = """
                INSERT OR IGNORE INTO assets
                    (type, path, created_at, source, speaker, status,
                     related_note, related_asset_ids, duration_seconds, summary)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, asset.type, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, asset.path, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, asset.createdAt, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, asset.source, -1, SQLITE_TRANSIENT)
            bindOptionalText(stmt, 5, asset.speaker)
            sqlite3_bind_text(stmt, 6, asset.status, -1, SQLITE_TRANSIENT)
            bindOptionalText(stmt, 7, asset.relatedNote)
            sqlite3_bind_text(stmt, 8, idsJSON, -1, SQLITE_TRANSIENT)
            if let d = asset.durationSeconds { sqlite3_bind_double(stmt, 9, d) }
            else { sqlite3_bind_null(stmt, 9) }
            bindOptionalText(stmt, 10, asset.summary)

            sqlite3_step(stmt)
            rowID = sqlite3_last_insert_rowid(db)
        }
        return rowID
    }

    /// Update the status and optional summary for an existing asset.
    func updateStatus(id: Int64, status: String, summary: String? = nil) {
        queue.sync {
            let sql = "UPDATE assets SET status = ?, summary = COALESCE(?, summary) WHERE id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, status, -1, SQLITE_TRANSIENT)
            bindOptionalText(stmt, 2, summary)
            sqlite3_bind_int64(stmt, 3, id)
            sqlite3_step(stmt)
        }
    }

    /// Link two assets as related (e.g. audio ↔ transcript).
    func link(assetID: Int64, to otherID: Int64) {
        queue.sync {
            for (a, b) in [(assetID, otherID), (otherID, assetID)] {
                let fetch = "SELECT related_asset_ids FROM assets WHERE id = ?"
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, fetch, -1, &stmt, nil) == SQLITE_OK else { continue }
                sqlite3_bind_int64(stmt, 1, a)
                var ids: [Int64] = []
                if sqlite3_step(stmt) == SQLITE_ROW,
                   let raw = sqlite3_column_text(stmt, 0),
                   let data = String(cString: raw).data(using: .utf8),
                   let decoded = try? JSONDecoder().decode([Int64].self, from: data) {
                    ids = decoded
                }
                sqlite3_finalize(stmt)

                if !ids.contains(b) { ids.append(b) }
                let json = (try? JSONEncoder().encode(ids))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

                let update = "UPDATE assets SET related_asset_ids = ? WHERE id = ?"
                var upd: OpaquePointer?
                guard sqlite3_prepare_v2(db, update, -1, &upd, nil) == SQLITE_OK else { continue }
                sqlite3_bind_text(upd, 1, json, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(upd, 2, a)
                sqlite3_step(upd)
                sqlite3_finalize(upd)
            }
        }
    }

    // MARK: - Schema

    private func open() {
        try? FileManager.default.createDirectory(
            atPath: (VaultConfig.dbPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        guard sqlite3_open(VaultConfig.dbPath, &db) == SQLITE_OK else { return }
        createSchema()
    }

    private func createSchema() {
        let sql = """
            CREATE TABLE IF NOT EXISTS assets (
                id                INTEGER PRIMARY KEY AUTOINCREMENT,
                type              TEXT    NOT NULL,
                path              TEXT    NOT NULL UNIQUE,
                created_at        TEXT    NOT NULL,
                source            TEXT    NOT NULL DEFAULT '',
                speaker           TEXT,
                status            TEXT    NOT NULL DEFAULT 'raw',
                related_note      TEXT,
                related_asset_ids TEXT    NOT NULL DEFAULT '[]',
                duration_seconds  REAL,
                summary           TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_assets_type   ON assets(type);
            CREATE INDEX IF NOT EXISTS idx_assets_status ON assets(status);
            CREATE INDEX IF NOT EXISTS idx_assets_source ON assets(source);
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    // MARK: - Helpers

    private func bindOptionalText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String?) {
        if let v = value { sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT) }
        else { sqlite3_bind_null(stmt, idx) }
    }

    deinit { sqlite3_close(db) }
}
