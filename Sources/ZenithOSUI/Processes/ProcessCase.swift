import Foundation

extension JSONValue {
    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    var prettyPrintedString: String {
        switch self {
        case let .string(value):
            return value
        case let .int(value):
            return String(value)
        case let .double(value):
            return String(value)
        case let .bool(value):
            return value ? "true" : "false"
        case .null:
            return "null"
        case let .object(value):
            return prettyPrintedJSONObject(value)
        case let .array(value):
            return prettyPrintedJSONObject(value)
        }
    }
}

private func jsonObject(from value: JSONValue) -> Any {
    switch value {
    case let .string(raw): return raw
    case let .int(raw): return raw
    case let .double(raw): return raw
    case let .bool(raw): return raw
    case let .object(raw): return raw.mapValues(jsonObject)
    case let .array(raw): return raw.map(jsonObject)
    case .null: return NSNull()
    }
}

private func prettyPrintedJSONObject(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: .prettyPrinted),
          let string = String(data: data, encoding: .utf8) else {
        return String(describing: value)
    }
    return string
}

// MARK: - Case (list item + detail header)

struct ProcessCase: Identifiable, Hashable, Decodable {
    let id: String
    let queueMessageId: String?
    let processName: String?
    let processPath: String?
    let processSource: String?
    let title: String?
    let objective: String?
    let sender: String?
    let status: String
    let createdAt: String
    let claimedAt: String?
    let completedAt: String?
    let dispatchPacketJson: JSONValue?

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (l: Self, r: Self) -> Bool { l.id == r.id }

    var displayTitle: String { title ?? processName ?? id }

    var statusLabel: String {
        switch status {
        case "COMPLETED": return "COMPLETE"
        case "IN_PROGRESS": return "IN PROGRESS"
        default: return status
        }
    }

    var statusColor: StatusColor {
        switch status {
        case "COMPLETED", "COMPLETE": return .green
        case "FAILED":                return .red
        case "OPEN":                  return .yellow
        case "READY":                 return .accent
        case "IN_PROGRESS":           return .blue
        case "BLOCKED":               return .orange
        default:         return .secondary
        }
    }
}

enum StatusColor { case green, yellow, red, accent, blue, orange, secondary }

// MARK: - Step

struct ProcessStep: Identifiable, Hashable, Decodable {
    let id: String
    let caseId: String
    let idx: Int
    let stepId: String
    let name: String
    let executor: String?
    let action: String?
    let argsJson: String?
    let resultJson: String?
    let status: String
    let runtimeStateJson: JSONValue?
    let createdAt: String
    let updatedAt: String
    let runtimeUpdatedAt: String?
    let completedAt: String?

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (l: Self, r: Self) -> Bool { l.id == r.id }

    var args: [String: Any] {
        guard let s = argsJson, let d = s.data(using: .utf8) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
    }

    var result: [String: Any] {
        guard let s = resultJson, let d = s.data(using: .utf8) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
    }

    var runtimeState: [String: JSONValue] {
        runtimeStateJson?.objectValue ?? [:]
    }

    var runtimeStatus: String? {
        runtimeState["status"]?.stringValue?.uppercased()
    }

    var isRunning: Bool  { status == "RUNNING" || status == "IN_PROGRESS" || runtimeStatus == "ACTIVE" || runtimeStatus == "RUNNING" }
    var isSuccess: Bool  { status == "SUCCESS" || status == "COMPLETED" }
    var isError: Bool    { status == "ERROR" || status == "FAILED" }
    var isPending: Bool  { status == "PENDING" }
    var isReady: Bool    { status == "READY" }

    var runtimeDisplayValue: String? {
        runtimeStateJson?.prettyPrintedString
    }
}

// MARK: - Slot

struct ProcessSlot: Identifiable, Hashable, Decodable {
    let id: String
    let caseId: String
    let name: String
    let value: String?
    let filledAt: String?

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (l: Self, r: Self) -> Bool { l.id == r.id }

    var isFilled: Bool { filledAt != nil }

    var displayValue: String {
        guard let v = value, !v.isEmpty else { return "—" }
        guard let data = v.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted),
              let str = String(data: pretty, encoding: .utf8) else { return v }
        return str
    }
}

// MARK: - Log

struct ProcessLog: Identifiable, Hashable, Decodable {
    let id: String
    let caseId: String
    let stepId: String?
    let type: String
    let message: String
    let metadataJson: JSONValue?
    let createdAt: String

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (l: Self, r: Self) -> Bool { l.id == r.id }
}

struct ProcessArtifact: Identifiable, Hashable, Decodable {
    let id: String
    let caseId: String
    let caseRunId: String
    let stepRunId: String?
    let spanId: String?
    let role: String
    let uri: String
    let sha256: String?
    let sizeBytes: Int?
    let contentType: String?
    let redactionStatus: String
    let metadataJson: JSONValue?
    let createdAt: String
}

struct CaseProgress: Hashable, Decodable {
    let totalSteps: Int
    let completedSteps: [String]
    let completedStepCount: Int
    let failedSteps: [String]
    let readySteps: [String]
    let runningSteps: [String]
}

// MARK: - API response wrappers

struct CasesListResponse: Decodable {
    let cases: [ProcessCase]
}

struct ProcessContract: Decodable {
    let title: String
    let description: String
    let processPath: String?
    let processHash: String
    let slotNames: [String]
    let rootInputs: [String]
    let variables: [String: VariableMeta]
    let producerMap: [String: Int]
    let consumerMap: [String: [Int]]
    let steps: [SpecStep]
    let dagEdges: [DagEdge]
}

struct CaseDetailResponse: Decodable {
    let caseItem: ProcessCase
    let contract: ProcessContract?
    let steps: [ProcessStep]
    let slots: [ProcessSlot]
    let logs: [ProcessLog]
    let artifacts: [ProcessArtifact]
    let progress: CaseProgress?

    enum CodingKeys: String, CodingKey {
        case caseItem = "case"
        case contract, steps, slots, logs, artifacts, progress
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        caseItem = try container.decode(ProcessCase.self, forKey: .caseItem)
        contract = try container.decodeIfPresent(ProcessContract.self, forKey: .contract)
        steps = try container.decodeIfPresent([ProcessStep].self, forKey: .steps) ?? []
        slots = try container.decodeIfPresent([ProcessSlot].self, forKey: .slots) ?? []
        logs = try container.decodeIfPresent([ProcessLog].self, forKey: .logs) ?? []
        artifacts = try container.decodeIfPresent([ProcessArtifact].self, forKey: .artifacts) ?? []
        progress = try container.decodeIfPresent(CaseProgress.self, forKey: .progress)
    }
}
