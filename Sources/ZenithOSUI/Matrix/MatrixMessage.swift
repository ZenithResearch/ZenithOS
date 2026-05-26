import Foundation

// MARK: - Models

struct MatrixMessage: Identifiable, Equatable {
    let id: String       // event ID
    let sender: String   // @user:server
    let body: String
    let timestamp: Date
}

struct MatrixSyncResult {
    let nextBatch: String
    let roomEvents: [String: [MatrixMessage]]   // roomId → new messages
}

// MARK: - MatrixClient extensions

extension MatrixClient {

    // MARK: Message history

    func messages(roomId: String, limit: Int = 50) async throws -> [MatrixMessage] {
        guard let token = accessToken else { throw MatrixError.notLoggedIn }
        let encoded = roomId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? roomId
        guard var comps = URLComponents(string: "\(baseURL)/_matrix/client/v3/rooms/\(encoded)/messages") else {
            throw MatrixError.badURL
        }
        comps.queryItems = [
            URLQueryItem(name: "dir",   value: "b"),
            URLQueryItem(name: "limit", value: "\(limit)"),
        ]
        guard let url = comps.url else { throw MatrixError.badURL }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let json = try await perform(req)
        let chunk = json["chunk"] as? [[String: Any]] ?? []
        return chunk.compactMap { Self.parseMessage($0) }.reversed()
    }

    // MARK: Send message

    func send(roomId: String, text: String) async throws {
        guard let token = accessToken else { throw MatrixError.notLoggedIn }
        let encoded = roomId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? roomId
        let txnId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let url = try endpoint("/_matrix/client/v3/rooms/\(encoded)/send/m.room.message/\(txnId)")
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json",  forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)",   forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "msgtype": "m.text",
            "body": text,
        ])
        try await perform(req)
    }

    // MARK: Sync (incremental)

    /// One sync request. Pass nil for `since` on the first call to get current state.
    /// Returns new events and a `nextBatch` token to pass on the next call.
    func sync(since: String?, timeout: Int = 10_000) async throws -> MatrixSyncResult {
        guard let token = accessToken else { throw MatrixError.notLoggedIn }
        guard var comps = URLComponents(string: "\(baseURL)/_matrix/client/v3/sync") else {
            throw MatrixError.badURL
        }
        var items: [URLQueryItem] = [URLQueryItem(name: "timeout", value: "\(timeout)")]
        if let s = since { items.append(URLQueryItem(name: "since", value: s)) }
        comps.queryItems = items
        guard let url = comps.url else { throw MatrixError.badURL }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = Double(timeout) / 1000 + 5
        let json = try await perform(req)
        guard let nextBatch = json["next_batch"] as? String else {
            throw MatrixError.httpError(0, "sync response missing next_batch")
        }
        var roomEvents: [String: [MatrixMessage]] = [:]
        if let rooms = json["rooms"] as? [String: Any],
           let joined = rooms["join"] as? [String: Any] {
            for (roomId, roomData) in joined {
                if let rd = roomData as? [String: Any],
                   let timeline = rd["timeline"] as? [String: Any],
                   let events = timeline["events"] as? [[String: Any]] {
                    let msgs = events.compactMap { Self.parseMessage($0) }
                    if !msgs.isEmpty { roomEvents[roomId] = msgs }
                }
            }
        }
        return MatrixSyncResult(nextBatch: nextBatch, roomEvents: roomEvents)
    }

    // MARK: Private helpers

    private static func parseMessage(_ event: [String: Any]) -> MatrixMessage? {
        guard event["type"] as? String == "m.room.message",
              let eventId = event["event_id"] as? String,
              let sender  = event["sender"]   as? String,
              let content = event["content"]  as? [String: Any],
              let body    = content["body"]   as? String
        else { return nil }
        let ts = event["origin_server_ts"] as? Double ?? 0
        let date = Date(timeIntervalSince1970: ts / 1000)
        return MatrixMessage(id: eventId, sender: sender, body: body, timestamp: date)
    }
}
