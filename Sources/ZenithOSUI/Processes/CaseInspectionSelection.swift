import Foundation

enum CaseInspectionSelection: Hashable, Identifiable {
    case overview
    case processDocument
    case requirement(id: String, title: String)
    case rootInput(name: String)
    case step(index: Int, stepID: String?)
    case slot(name: String)
    case edge(from: Int, to: Int, slotNames: [String])
    case caseLog(id: String)
    case execution(stepID: String?)
    case raw

    var id: String {
        switch self {
        case .overview:
            return "overview"
        case .processDocument:
            return "process-document"
        case let .requirement(id, title):
            return "requirement:\(id):\(title)"
        case let .rootInput(name):
            return "root-input:\(name)"
        case let .step(index, stepID):
            return "step:\(index):\(stepID ?? "")"
        case let .slot(name):
            return "slot:\(name)"
        case let .edge(from, to, slotNames):
            return "edge:\(from):\(to):\(slotNames.joined(separator: ","))"
        case let .caseLog(id):
            return "case-log:\(id)"
        case let .execution(stepID):
            return "execution:\(stepID ?? "case")"
        case .raw:
            return "raw"
        }
    }

    var title: String {
        switch self {
        case .overview:
            return "Overview"
        case .processDocument:
            return "Process document"
        case let .requirement(_, title):
            return title
        case let .rootInput(name):
            return name
        case let .step(index, _):
            return "Step \(index + 1)"
        case let .slot(name):
            return name
        case let .edge(from, to, slotNames):
            let label = slotNames.isEmpty ? "dependency" : slotNames.joined(separator: ", ")
            return "\(from + 1) → \(to + 1): \(label)"
        case .caseLog:
            return "Log entry"
        case .execution:
            return "Execution"
        case .raw:
            return "Raw fields"
        }
    }

    static func selectionForStep(arrayIndex: Int, step: SpecStep) -> CaseInspectionSelection {
        .step(index: arrayIndex, stepID: String(step.id))
    }
}
