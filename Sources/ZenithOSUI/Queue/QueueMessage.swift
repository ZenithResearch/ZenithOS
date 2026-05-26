import Foundation

// MARK: - JSONValue — arbitrary JSON for payload / metadata

enum JSONValue: Codable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil()                                   { self = .null;         return }
        if let v = try? c.decode(Bool.self)                { self = .bool(v);      return }
        if let v = try? c.decode(Int.self)                 { self = .int(v);       return }
        if let v = try? c.decode(Double.self)              { self = .double(v);    return }
        if let v = try? c.decode(String.self)              { self = .string(v);    return }
        if let v = try? c.decode([JSONValue].self)         { self = .array(v);     return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v);    return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unknown JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:          try c.encodeNil()
        case .bool(let v):   try c.encode(v)
        case .int(let v):    try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v):  try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

extension [String: JSONValue] {
    var prettyJSON: String {
        guard let data = try? JSONEncoder().encode(self),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted),
              let str = String(data: pretty, encoding: .utf8)
        else { return "{}" }
        return str
    }
}

// MARK: - Message model

struct QueueMessage: Codable, Identifiable, Hashable {
    let id: String
    let queue_name: String
    let event_type: String
    let source_type: String
    let sender: String
    let message_body: String
    let payload: [String: JSONValue]
    let status: String
    let priority: Int
    let created_at: String
    let claimed_at: String
    let done_at: String
    let worker_id: String
    let retry_count: Int
    let max_retries: Int
    let claim_timeout_s: Int
    let error: String
    let metadata: [String: JSONValue]
}

struct PeekResponse: Codable {
    let messages: [QueueMessage]
}

// MARK: - Timestamp formatting

extension String {
    var formattedTimestamp: String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        if let date = iso.date(from: self) {
            let f = DateFormatter()
            f.dateStyle = .short
            f.timeStyle = .short
            return f.string(from: date)
        }
        return self
    }
}
