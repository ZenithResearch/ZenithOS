import Foundation

// MARK: - Models

struct VariableMeta: Decodable {
    let description: String
    let type: String
}

struct ProcessSpec {
    let title: String
    let description: String
    let steps: [SpecStep]
    let variables: [String: VariableMeta]

    var dagEdges: [DagEdge] {
        var edges: [DagEdge] = []
        for i in 0 ..< steps.count {
            let produced = Set(steps[i].outputs.map(\.name))
            for j in (i + 1) ..< steps.count {
                let consumed = Set(steps[j].inputItems.map(\.name))
                let shared = produced.intersection(consumed)
                guard !shared.isEmpty else { continue }
                let label = shared.sorted().first ?? "→"
                edges.append(DagEdge(from: i, to: j, label: label, isSkip: j > i + 1))
            }
        }
        return edges
    }
}

struct IOItem: Decodable {
    let name: String
    let detail: String       // raw content (schema text for output types)
    let description: String  // human description from ## Variables table
    let type: String         // data type from ## Variables table
    let isResource: Bool     // legacy marker; explicit resources now come from step.resources only

    init(name: String, detail: String, description: String = "", type: String = "", isResource: Bool = false) {
        self.name = name
        self.detail = detail
        self.description = description
        self.type = type
        self.isResource = isResource
    }
}

struct SpecStep: Identifiable, Decodable {
    let id: Int
    let number: Int
    let title: String
    let instructions: String
    let inputs: String           // raw text
    let inputItems: [IOItem]     // enriched with variable metadata, built during parse
    let outputs: [IOItem]
    let skills: [String]
    let resources: [String]
    let suggestedResources: [String]
    let tools: [String]

    enum CodingKeys: String, CodingKey {
        case id, number, title, instructions, inputs, inputItems, outputs, skills, resources, tools
        case suggestedResources
    }

    init(
        id: Int,
        number: Int,
        title: String,
        instructions: String,
        inputs: String,
        inputItems: [IOItem],
        outputs: [IOItem],
        skills: [String],
        resources: [String],
        suggestedResources: [String] = [],
        tools: [String]
    ) {
        self.id = id
        self.number = number
        self.title = title
        self.instructions = instructions
        self.inputs = inputs
        self.inputItems = inputItems
        self.outputs = outputs
        self.skills = skills
        self.resources = resources
        self.suggestedResources = suggestedResources
        self.tools = tools
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        number = try container.decode(Int.self, forKey: .number)
        title = try container.decode(String.self, forKey: .title)
        instructions = try container.decode(String.self, forKey: .instructions)
        inputs = try container.decode(String.self, forKey: .inputs)
        inputItems = try container.decode([IOItem].self, forKey: .inputItems)
        outputs = try container.decode([IOItem].self, forKey: .outputs)
        skills = try container.decode([String].self, forKey: .skills)
        resources = try container.decode([String].self, forKey: .resources)
        suggestedResources = try container.decodeIfPresent([String].self, forKey: .suggestedResources) ?? []
        tools = try container.decode([String].self, forKey: .tools)
    }

    var outputLabel: String {
        guard let first = outputs.first else { return "→" }
        return String(first.name.prefix(24))
    }
}

struct DagEdge: Decodable {
    let from: Int
    let to: Int
    let label: String
    let isSkip: Bool
}

// MARK: - Parser

enum ProcessSpecParser {
    static func parse(_ markdown: String) -> ProcessSpec {
        let lines = markdown.components(separatedBy: .newlines)

        // Pass 1: extract variable metadata from ## Variables table
        let variables = extractVariables(lines)

        // Pass 2: parse spec structure
        var title = ""
        var description = ""
        var steps: [SpecStep] = []

        var mode: Mode = .preamble
        var descBuf: [String] = []
        var stepNum = 0
        var stepTitle = ""
        var instrBuf: [String] = []
        var inputBuf: [String] = []
        var parsedOutputs: [IOItem] = []
        var currentOutputName = ""
        var currentOutputContentBuf: [String] = []
        var skills: [String] = []
        var resources: [String] = []
        var suggestedResources: [String] = []
        var tools: [String] = []
        var currentField: CurrentField = .none
        var inFence = false

        enum Mode { case preamble, desc, steps, stepBody }
        enum CurrentField { case none, input, output, skill, resource, suggestedResource, tool }

        func buildInputItems(from rawInputs: String) -> [IOItem] {
            let names = ProcessSpecParser.extractBacktickNames(rawInputs)
            guard !names.isEmpty else {
                return rawInputs.isEmpty ? [] : [IOItem(name: "input", detail: rawInputs)]
            }
            return names.map { name in
                let meta = variables[name]
                return IOItem(
                    name: name,
                    detail: "",
                    description: meta?.description ?? "",
                    type: meta?.type ?? "",
                    isResource: false
                )
            }
        }

        func flushOutputItem() {
            guard !currentOutputName.isEmpty else { return }
            let content = currentOutputContentBuf
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let typeLower = currentOutputName.lowercased()

            if let meta = variables[currentOutputName] {
                parsedOutputs.append(IOItem(
                    name: currentOutputName,
                    detail: "",
                    description: meta.description,
                    type: meta.type,
                    isResource: false
                ))
            } else if !typeLower.contains("process state") {
                currentOutputName = ""
                currentOutputContentBuf = []
                return
            } else {
                let keys = ProcessSpecParser.extractJSONKeys(content)
                if keys.isEmpty {
                    parsedOutputs.append(IOItem(name: currentOutputName, detail: content))
                } else {
                    for key in keys {
                        let meta = variables[key]
                        parsedOutputs.append(IOItem(
                            name: key,
                            detail: "",
                            description: meta?.description ?? "",
                            type: meta?.type ?? currentOutputName,
                            isResource: false
                        ))
                    }
                }
            }

            currentOutputName = ""
            currentOutputContentBuf = []
        }

        func flushStep() {
            guard stepNum > 0 else { return }
            flushOutputItem()
            let rawInputs = inputBuf.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            steps.append(SpecStep(
                id: stepNum,
                number: stepNum,
                title: stepTitle,
                instructions: instrBuf.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                inputs: rawInputs,
                inputItems: buildInputItems(from: rawInputs),
                outputs: parsedOutputs,
                skills: skills,
                resources: resources,
                suggestedResources: suggestedResources,
                tools: tools
            ))
        }

        func resetStep() {
            instrBuf = []; inputBuf = []
            parsedOutputs = []; currentOutputName = ""; currentOutputContentBuf = []
            skills = []; resources = []; suggestedResources = []; tools = []
            currentField = .none
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                switch mode {
                case .desc:
                    descBuf.append(line)
                case .stepBody:
                    switch currentField {
                    case .input:    inputBuf.append(trimmed)
                    case .output:   currentOutputContentBuf.append(line)
                    case .skill:    if !trimmed.isEmpty { skills.append(ProcessSpecParser.normalizeDeclaredCapability(trimmed)) }
                    case .resource: if !trimmed.isEmpty { resources.append(ProcessSpecParser.normalizeDeclaredCapability(trimmed)) }
                    case .suggestedResource:
                        if !trimmed.isEmpty { suggestedResources.append(ProcessSpecParser.normalizeDeclaredCapability(trimmed)) }
                    case .tool:     if !trimmed.isEmpty { tools.append(ProcessSpecParser.normalizeDeclaredCapability(trimmed)) }
                    case .none:     instrBuf.append(trimmed)
                    }
                default:
                    break
                }
                inFence.toggle()
                continue
            }

            if inFence {
                switch mode {
                case .desc:
                    descBuf.append(line)
                case .stepBody:
                    switch currentField {
                    case .input:    inputBuf.append(trimmed)
                    case .output:   currentOutputContentBuf.append(line)
                    case .skill:    if !trimmed.isEmpty { skills.append(ProcessSpecParser.normalizeDeclaredCapability(trimmed)) }
                    case .resource: if !trimmed.isEmpty { resources.append(ProcessSpecParser.normalizeDeclaredCapability(trimmed)) }
                    case .suggestedResource:
                        if !trimmed.isEmpty { suggestedResources.append(ProcessSpecParser.normalizeDeclaredCapability(trimmed)) }
                    case .tool:     if !trimmed.isEmpty { tools.append(ProcessSpecParser.normalizeDeclaredCapability(trimmed)) }
                    case .none:     instrBuf.append(trimmed)
                    }
                default:
                    break
                }
                continue
            }

            if trimmed.hasPrefix("# ") && title.isEmpty && !trimmed.hasPrefix("## ") {
                title = String(trimmed.dropFirst(2))
                continue
            }

            if trimmed == "## What this process does" { mode = .desc; continue }
            if trimmed == "## Steps" { mode = .steps; continue }
            if trimmed.hasPrefix("## ") && mode != .preamble {
                if mode == .stepBody { flushStep() }
                mode = .preamble
                continue
            }

            switch mode {
            case .preamble: break

            case .desc:
                if trimmed == "---" { mode = .preamble }
                else { descBuf.append(line) }

            case .steps:
                if trimmed.hasPrefix("### Step ") {
                    flushStep()
                    let body = String(trimmed.dropFirst("### Step ".count))
                    if let r = body.range(of: " — ") ?? body.range(of: " -- ") {
                        stepNum = Int(body[body.startIndex ..< r.lowerBound].trimmingCharacters(in: .whitespaces)) ?? (stepNum + 1)
                        stepTitle = String(body[r.upperBound...])
                    } else {
                        stepNum += 1; stepTitle = body
                    }
                    resetStep(); mode = .stepBody
                }

            case .stepBody:
                if trimmed.hasPrefix("### Step ") {
                    flushStep()
                    let body = String(trimmed.dropFirst("### Step ".count))
                    if let r = body.range(of: " — ") ?? body.range(of: " -- ") {
                        stepNum = Int(body[body.startIndex ..< r.lowerBound].trimmingCharacters(in: .whitespaces)) ?? (stepNum + 1)
                        stepTitle = String(body[r.upperBound...])
                    } else {
                        stepNum += 1; stepTitle = body
                    }
                    resetStep(); continue
                }
                if trimmed.hasPrefix("## ") { flushStep(); mode = .preamble; continue }
                if trimmed == "---" { currentField = .none; continue }

                let lower = trimmed.lowercased()
                if lower.hasPrefix("**input") {
                    currentField = .input
                    let rest = stripBoldLabel(trimmed)
                    if !rest.isEmpty { inputBuf.append(rest) }
                    continue
                }
                if lower.hasPrefix("**processing") {
                    currentField = .none
                    let rest = stripBoldLabel(trimmed)
                    if !rest.isEmpty { instrBuf.append(rest) }
                    continue
                }
                if lower.hasPrefix("**instructions") {
                    currentField = .none
                    let rest = stripBoldLabel(trimmed)
                    if !rest.isEmpty { instrBuf.append(rest) }
                    continue
                }
                if lower.hasPrefix("**output") {
                    flushOutputItem()
                    currentOutputName = extractOutputName(trimmed)
                    currentField = .output
                    let rest = stripBoldLabel(trimmed)
                    if !rest.isEmpty { currentOutputContentBuf.append(rest) }
                    continue
                }
                if lower.hasPrefix("**skill") {
                    currentField = .skill
                    let rest = stripBoldLabel(trimmed)
                    if !rest.isEmpty { skills.append(ProcessSpecParser.normalizeDeclaredCapability(rest)) }
                    continue
                }
                if lower.hasPrefix("**required resource") {
                    currentField = .resource
                    let rest = stripBoldLabel(trimmed)
                    if !rest.isEmpty { resources.append(ProcessSpecParser.normalizeDeclaredCapability(rest)) }
                    continue
                }
                if lower.hasPrefix("**suggested resource") {
                    currentField = .suggestedResource
                    let rest = stripBoldLabel(trimmed)
                    if !rest.isEmpty { suggestedResources.append(ProcessSpecParser.normalizeDeclaredCapability(rest)) }
                    continue
                }
                if lower.hasPrefix("**resource") {
                    currentField = .resource
                    let rest = stripBoldLabel(trimmed)
                    if !rest.isEmpty { resources.append(ProcessSpecParser.normalizeDeclaredCapability(rest)) }
                    continue
                }
                if lower.hasPrefix("**tool") {
                    currentField = .tool
                    let rest = stripBoldLabel(trimmed)
                    if !rest.isEmpty { tools.append(ProcessSpecParser.normalizeDeclaredCapability(rest)) }
                    continue
                }

                switch currentField {
                case .input:    inputBuf.append(trimmed)
                case .output:   currentOutputContentBuf.append(line)
                case .skill:    if !trimmed.isEmpty { skills.append(ProcessSpecParser.normalizeDeclaredCapability(trimmed)) }
                case .resource: if !trimmed.isEmpty { resources.append(ProcessSpecParser.normalizeDeclaredCapability(trimmed)) }
                case .suggestedResource:
                    if !trimmed.isEmpty { suggestedResources.append(ProcessSpecParser.normalizeDeclaredCapability(trimmed)) }
                case .tool:     if !trimmed.isEmpty { tools.append(ProcessSpecParser.normalizeDeclaredCapability(trimmed)) }
                case .none:     instrBuf.append(trimmed)
                }
            }
        }

        flushStep()
        description = descBuf.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return ProcessSpec(title: title, description: description, steps: steps, variables: variables)
    }

    // MARK: - Variable metadata (## Variables table)

    private static func extractVariables(_ lines: [String]) -> [String: VariableMeta] {
        var vars: [String: VariableMeta] = [:]
        var inSection = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "## Variables" { inSection = true; continue }
            if inSection {
                if trimmed.hasPrefix("## ") { break }
                guard trimmed.hasPrefix("|") else { continue }
                let cols = trimmed
                    .split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                guard cols.count >= 3 else { continue }
                // Rows without a backtick-wrapped name are headers or separators — skip
                let names = extractBacktickNames(cols[0])
                guard let varName = names.first else { continue }
                vars[varName] = VariableMeta(description: cols[2], type: cols[1])
            }
        }
        return vars
    }

    // MARK: - Helpers

    // Only extracts top-level keys (≤2 leading spaces) to avoid pulling nested schema sub-fields
    static func extractJSONKeys(_ content: String) -> [String] {
        var keys: [String] = []
        guard let regex = try? NSRegularExpression(pattern: #"^ {0,2}"([a-zA-Z_][a-zA-Z0-9_]*)"\s*:"#) else { return keys }
        for line in content.components(separatedBy: .newlines) {
            let range = NSRange(line.startIndex..., in: line)
            if let match = regex.firstMatch(in: line, range: range),
               let keyRange = Range(match.range(at: 1), in: line) {
                keys.append(String(line[keyRange]))
            }
        }
        return keys
    }

    static func extractBacktickNames(_ text: String) -> [String] {
        var names: [String] = []
        var s = text[...]
        while let open = s.firstIndex(of: "`") {
            let after = s.index(after: open)
            guard after < s.endIndex else { break }
            if let close = s[after...].firstIndex(of: "`") {
                let name = String(s[after..<close])
                if !name.isEmpty { names.append(name) }
                s = s[s.index(after: close)...]
            } else { break }
        }
        return names
    }

    private static func extractOutputName(_ s: String) -> String {
        if let open = s.firstIndex(of: "("),
           let close = s[s.index(after: open)...].firstIndex(of: ")") {
            return String(s[s.index(after: open)..<close])
        }
        return "output"
    }

    private static func stripBoldLabel(_ s: String) -> String {
        var work = s
        if work.hasPrefix("**") { work = String(work.dropFirst(2)) }
        if let r = work.range(of: ":**") {
            work = String(work[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        } else if let r = work.range(of: "**") {
            work = String(work[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return work
    }

    private static func normalizeDeclaredCapability(_ text: String) -> String {
        var normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("- ") {
            normalized = String(normalized.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if normalized.hasPrefix("`"), normalized.hasSuffix("`"), normalized.count >= 2 {
            normalized = String(normalized.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return normalized
    }
}
