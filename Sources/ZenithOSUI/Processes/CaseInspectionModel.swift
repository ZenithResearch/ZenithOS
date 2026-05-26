import Foundation

struct CaseInspectionContext {
    let processCase: ProcessCase
    let detail: CaseDetailResponse?
    let steps: [SpecStep]
    let variables: [String: VariableMeta]
    let rootInputs: [String]
    let producerMap: [String: Int]
    let consumerMap: [String: [Int]]
    let rawProcessMarkdown: String?
    let rawProcessSourceURL: URL?
    let artifactMounts: [HubArtifactMount]
    let artifactContentBaseURL: URL?
    let usesAdminArtifactAccess: Bool
}

struct CaseStepInspection {
    let selection: CaseInspectionSelection
    let specStep: SpecStep
    let processStep: ProcessStep?
    let inputSlots: [CaseSlotInspection]
    let outputSlots: [CaseSlotInspection]
    let logs: [ProcessLog]
}

struct CaseSlotInspection {
    let selection: CaseInspectionSelection
    let name: String
    let variable: VariableMeta?
    let slot: ProcessSlot?
    let producerStep: SpecStep?
    let consumerSteps: [SpecStep]
    let valueKind: SlotValueKind
    let fileReference: SlotFileReference?

    var isFilled: Bool { slot?.isFilled ?? false }
    var displayValue: String { slot?.displayValue ?? "Not filled yet." }
}

enum SlotValueKind: Equatable {
    case plain
    case filePath(FilePreviewKind)
    case url
}

enum FilePreviewKind: Equatable {
    case markdown
    case genericFile
}

struct SlotFileReference: Equatable, Identifiable {
    let rawValue: String
    let url: URL?
    let displayPath: String
    let previewKind: FilePreviewKind
    let resolutionState: FileResolutionState
    let sourceLabel: String?
    let artifactID: String?
    let artifactContentPath: String?
    let artifactContentURL: URL?
    let usesAdminArtifactAccess: Bool

    var id: String { "\(resolutionState)-\(previewKind)-\(displayPath)" }
    var isReadableFile: Bool { [.localFile, .mountedFile].contains(resolutionState) && url?.isFileURL == true }
    var isLocalFile: Bool { isReadableFile }
    var isMarkdownPreviewable: Bool { (isReadableFile || resolutionState == .hubArtifact) && previewKind == .markdown }
}

enum FileResolutionState: Equatable {
    case localFile
    case mountedFile
    case hubArtifact
    case missing
    case remoteURL
    case unsupported
}

struct CaseEdgeInspection {
    let selection: CaseInspectionSelection
    let fromStep: SpecStep
    let toStep: SpecStep
    let slotNames: [String]
    let slots: [CaseSlotInspection]
}

enum CaseInspectionModel {
    static func fallbackRootInputs(steps: [SpecStep], producerMap: [String: Int]) -> [String] {
        let produced = Set(steps.flatMap { $0.outputs.map(\.name) }).union(producerMap.keys)
        var roots: [String] = []
        var seen = Set<String>()
        for step in steps.sorted(by: { $0.number < $1.number }) {
            for item in step.inputItems where !produced.contains(item.name) {
                if seen.insert(item.name).inserted { roots.append(item.name) }
            }
        }
        return roots
    }

    static func allSlotNames(context: CaseInspectionContext) -> [String] {
        var names: [String] = []
        var seen = Set<String>()

        func append(_ name: String) {
            guard !name.isEmpty, seen.insert(name).inserted else { return }
            names.append(name)
        }

        context.rootInputs.forEach(append)
        context.variables.keys.sorted().forEach(append)
        for step in context.steps {
            step.inputItems.map(\.name).forEach(append)
            step.outputs.map(\.name).forEach(append)
        }
        (context.detail?.slots ?? []).map(\.name).forEach(append)
        return names
    }

    static func slotInspection(name: String, context: CaseInspectionContext) -> CaseSlotInspection {
        let slot = context.detail?.slots.first(where: { $0.name == name })
        let valueKind = slotValueKind(for: name, context: context)
        let allowArrayValue = allowsArrayFileReference(for: name, context: context)
        return CaseSlotInspection(
            selection: .slot(name: name),
            name: name,
            variable: context.variables[name],
            slot: slot,
            producerStep: producerStep(for: name, context: context),
            consumerSteps: consumerSteps(for: name, context: context),
            valueKind: valueKind,
            fileReference: fileReference(for: slot, kind: valueKind, allowArrayValue: allowArrayValue, context: context)
        )
    }

    static func stepInspection(index: Int, stepID: String?, context: CaseInspectionContext) -> CaseStepInspection? {
        guard context.steps.indices.contains(index) else { return nil }
        let specStep = context.steps[index]
        let processStep = context.detail?.steps.first { persisted in
            if let stepID, persisted.stepId == stepID { return true }
            if let stepID, persisted.id == stepID { return true }
            return persisted.idx == index || persisted.stepId == String(specStep.id)
        }
        let logs = context.detail?.logs.filter { log in
            guard let processStep else { return false }
            return log.stepId == processStep.id || log.stepId == processStep.stepId
        } ?? []
        return CaseStepInspection(
            selection: .selectionForStep(arrayIndex: index, step: specStep),
            specStep: specStep,
            processStep: processStep,
            inputSlots: specStep.inputItems.map { slotInspection(name: $0.name, context: context) },
            outputSlots: specStep.outputs.map { slotInspection(name: $0.name, context: context) },
            logs: logs
        )
    }

    static func edgeInspection(from: Int, to: Int, context: CaseInspectionContext) -> CaseEdgeInspection? {
        guard context.steps.indices.contains(from), context.steps.indices.contains(to) else { return nil }
        let fromStep = context.steps[from]
        let toStep = context.steps[to]
        let names = slotNamesForEdge(from: fromStep, to: toStep, context: context)
        return CaseEdgeInspection(
            selection: .edge(from: from, to: to, slotNames: names),
            fromStep: fromStep,
            toStep: toStep,
            slotNames: names,
            slots: names.map { slotInspection(name: $0, context: context) }
        )
    }

    static func slotNamesForEdge(from: SpecStep, to: SpecStep, context: CaseInspectionContext) -> [String] {
        let produced = Set(from.outputs.map(\.name))
        let consumed = Set(to.inputItems.map(\.name))
        return produced.intersection(consumed).sorted()
    }

    static func slotValueKind(for name: String, context: CaseInspectionContext) -> SlotValueKind {
        let normalizedTypes = slotTypeCandidates(for: name, context: context).map(normalizeType)
        if normalizedTypes.contains(where: isMarkdownType) { return .filePath(.markdown) }
        if normalizedTypes.contains(where: isURLType) { return .url }
        if normalizedTypes.contains(where: isFilePathType) { return .filePath(.genericFile) }
        return .plain
    }

    static func slotTypeCandidates(for name: String, context: CaseInspectionContext) -> [String] {
        var candidates: [String] = []
        var seen = Set<String>()

        func append(_ raw: String?) {
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else { return }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { return }
            candidates.append(trimmed)
        }

        append(context.variables[name]?.type)
        for step in context.steps {
            step.inputItems.filter { $0.name == name }.forEach { append($0.type) }
            step.outputs.filter { $0.name == name }.forEach { append($0.type) }
        }
        return candidates
    }

    static func fileReference(
        for slot: ProcessSlot?,
        kind: SlotValueKind,
        allowArrayValue: Bool,
        context: CaseInspectionContext
    ) -> SlotFileReference? {
        guard kind != .plain,
              let raw = slot?.value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let path = structurallyExtractPath(from: raw, allowArrayValue: allowArrayValue) else { return nil }
        return resolveFileReference(path, kind: kind, context: context)
    }

    private static func normalizeType(_ raw: String) -> String {
        raw.lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isMarkdownType(_ normalized: String) -> Bool {
        let tokens = typeTokens(normalized)
        return tokens.contains("markdown")
            || tokens.contains("md")
            || normalized.contains("markdown_file")
            || normalized.contains("markdown_path")
    }

    private static func isURLType(_ normalized: String) -> Bool {
        let tokens = typeTokens(normalized)
        return tokens.contains("url") || tokens.contains("uri") || normalized.contains("http_url")
    }

    private static func isFilePathType(_ normalized: String) -> Bool {
        let tokens = typeTokens(normalized)
        return tokens.contains("path")
            || tokens.contains("file")
            || tokens.contains("filepath")
            || tokens.contains("document")
            || normalized.contains("file_path")
            || normalized.contains("document_path")
            || normalized.contains("local_file")
    }

    private static func allowsArrayFileReference(for name: String, context: CaseInspectionContext) -> Bool {
        slotTypeCandidates(for: name, context: context).map(normalizeType).contains { normalized in
            let tokens = typeTokens(normalized)
            return tokens.contains("list") || tokens.contains("array") || tokens.contains("collection")
        }
    }

    private static func typeTokens(_ normalized: String) -> Set<String> {
        Set(normalized.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            .union(normalized.split(separator: "_").map(String.init))
    }

    private static func structurallyExtractPath(from raw: String, allowArrayValue: Bool) -> String? {
        if let jsonValue = decodeJSONValue(raw) {
            return extractPath(from: jsonValue, allowArray: allowArrayValue)
        }
        return raw
    }

    private static func decodeJSONValue(_ raw: String) -> Any? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func extractPath(from value: Any, allowArray: Bool) -> String? {
        if let string = value as? String {
            return string.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        if let object = value as? [String: Any] {
            for key in ["path", "file_path", "filepath", "url", "uri", "href", "source", "source_path"] {
                if let extracted = object[key].flatMap({ extractPath(from: $0, allowArray: false) }) {
                    return extracted
                }
            }
            return nil
        }
        if allowArray, let array = value as? [Any] {
            for item in array {
                if let extracted = extractPath(from: item, allowArray: false) {
                    return extracted
                }
            }
        }
        return nil
    }

    private static func resolveFileReference(_ rawPath: String, kind: SlotValueKind, context: CaseInspectionContext) -> SlotFileReference? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let pathWithoutFragment = trimmed.split(separator: "#", maxSplits: 1).first.map(String.init) ?? trimmed
        let decoded = pathWithoutFragment.removingPercentEncoding ?? pathWithoutFragment
        let defaultPreviewKind: FilePreviewKind = {
            if case let .filePath(previewKind) = kind { return previewKind }
            return .genericFile
        }()

        if let remoteURL = URL(string: decoded),
           let scheme = remoteURL.scheme?.lowercased(),
           ["http", "https"].contains(scheme) {
            return SlotFileReference(
                rawValue: rawPath,
                url: remoteURL,
                displayPath: decoded,
                previewKind: previewKind(forPath: decoded, defaultKind: defaultPreviewKind),
                resolutionState: .remoteURL,
                sourceLabel: nil,
                artifactID: nil,
                artifactContentPath: nil,
                artifactContentURL: nil,
                usesAdminArtifactAccess: false
            )
        }

        if decoded.hasPrefix("file://"),
           let fileURL = URL(string: decoded) {
            return localReference(for: URL(fileURLWithPath: fileURL.path), rawPath: rawPath, defaultPreviewKind: defaultPreviewKind)
        }

        let expanded = decoded.hasPrefix("~/")
            ? NSString(string: decoded).expandingTildeInPath
            : decoded

        if expanded.hasPrefix("/") {
            let absoluteReference = localReference(for: URL(fileURLWithPath: expanded), rawPath: rawPath, defaultPreviewKind: defaultPreviewKind)
            if absoluteReference.resolutionState == .localFile {
                return absoluteReference
            }
            if let mounted = mountedReference(forRuntimePath: expanded, rawPath: rawPath, defaultPreviewKind: defaultPreviewKind, mounts: context.artifactMounts) {
                return mounted
            }
            if let artifact = artifactReference(forRuntimePath: expanded, rawPath: rawPath, defaultPreviewKind: defaultPreviewKind, context: context) {
                return artifact
            }
            return absoluteReference
        }

        for base in fileRelativeBases(context: context) {
            let candidate = base.appendingPathComponent(expanded)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return localReference(for: candidate, rawPath: rawPath, defaultPreviewKind: defaultPreviewKind)
            }
        }

        return SlotFileReference(
            rawValue: rawPath,
            url: nil,
            displayPath: decoded,
            previewKind: previewKind(forPath: decoded, defaultKind: defaultPreviewKind),
            resolutionState: .missing,
            sourceLabel: nil,
            artifactID: nil,
            artifactContentPath: nil,
            artifactContentURL: nil,
            usesAdminArtifactAccess: false
        )
    }

    private static func mountedReference(forRuntimePath runtimePath: String, rawPath: String, defaultPreviewKind: FilePreviewKind, mounts: [HubArtifactMount]) -> SlotFileReference? {
        guard let resolution = HubArtifactMountResolver.resolve(runtimePath: runtimePath, mounts: mounts) else { return nil }
        return SlotFileReference(
            rawValue: rawPath,
            url: resolution.fileURL,
            displayPath: resolution.fileURL.path,
            previewKind: previewKind(forPath: resolution.fileURL.path, defaultKind: defaultPreviewKind),
            resolutionState: .mountedFile,
            sourceLabel: resolution.label,
            artifactID: nil,
            artifactContentPath: nil,
            artifactContentURL: nil,
            usesAdminArtifactAccess: false
        )
    }

    private static func artifactReference(forRuntimePath runtimePath: String, rawPath: String, defaultPreviewKind: FilePreviewKind, context: CaseInspectionContext) -> SlotFileReference? {
        guard let artifact = matchingArtifact(forRuntimePath: runtimePath, context: context),
              let baseURL = context.artifactContentBaseURL else { return nil }
        let contentPath = context.usesAdminArtifactAccess
            ? "v1/admin/execution-artifacts/\(artifact.id)/content"
            : "execution-artifacts/\(artifact.id)/content"
        let contentURL = appendPath(contentPath, to: baseURL)
        return SlotFileReference(
            rawValue: rawPath,
            url: nil,
            displayPath: runtimePath,
            previewKind: previewKind(forPath: runtimePath, defaultKind: defaultPreviewKind),
            resolutionState: .hubArtifact,
            sourceLabel: artifact.role,
            artifactID: artifact.id,
            artifactContentPath: contentPath,
            artifactContentURL: contentURL,
            usesAdminArtifactAccess: context.usesAdminArtifactAccess
        )
    }

    private static func matchingArtifact(forRuntimePath runtimePath: String, context: CaseInspectionContext) -> ProcessArtifact? {
        let normalizedRuntimePath = URL(fileURLWithPath: runtimePath).standardizedFileURL.path
        return context.detail?.artifacts.first { artifact in
            let uri = artifact.uri.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawPath: String
            if uri.hasPrefix("dir:") { rawPath = String(uri.dropFirst(4)) }
            else if uri.hasPrefix("file:") { rawPath = String(uri.dropFirst(5)) }
            else { return false }
            return URL(fileURLWithPath: rawPath).standardizedFileURL.path == normalizedRuntimePath
        }
    }

    private static func appendPath(_ path: String, to baseURL: URL) -> URL {
        var url = baseURL
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        return url
    }

    private static func localReference(for url: URL, rawPath: String, defaultPreviewKind: FilePreviewKind) -> SlotFileReference {
        let standardized = url.resolvingSymlinksInPath().standardizedFileURL
        let exists = FileManager.default.fileExists(atPath: standardized.path)
        return SlotFileReference(
            rawValue: rawPath,
            url: exists ? standardized : nil,
            displayPath: standardized.path,
            previewKind: previewKind(forPath: standardized.path, defaultKind: defaultPreviewKind),
            resolutionState: exists ? .localFile : .missing,
            sourceLabel: nil,
            artifactID: nil,
            artifactContentPath: nil,
            artifactContentURL: nil,
            usesAdminArtifactAccess: false
        )
    }

    private static func previewKind(forPath path: String, defaultKind: FilePreviewKind) -> FilePreviewKind {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        if ["md", "markdown"].contains(ext) { return .markdown }
        return defaultKind
    }

    private static func fileRelativeBases(context: CaseInspectionContext) -> [URL] {
        var bases: [URL] = []
        var seen = Set<String>()

        func append(_ url: URL?) {
            guard let url else { return }
            let standardized = url.resolvingSymlinksInPath().standardizedFileURL
            guard seen.insert(standardized.path).inserted else { return }
            bases.append(standardized)
        }

        if let processURL = context.rawProcessSourceURL?.resolvingSymlinksInPath().standardizedFileURL {
            var cursor = processURL.deletingLastPathComponent()
            while cursor.path != "/" {
                append(cursor)
                cursor.deleteLastPathComponent()
            }
        }
        append(FileStore.hubRoot)
        append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        return bases
    }

    private static func producerStep(for name: String, context: CaseInspectionContext) -> SpecStep? {
        if let producerIndex = context.producerMap[name] {
            if let exact = context.steps.first(where: { $0.number == producerIndex || $0.id == producerIndex }) {
                return exact
            }
            if context.steps.indices.contains(producerIndex) { return context.steps[producerIndex] }
            let zeroBased = producerIndex - 1
            if context.steps.indices.contains(zeroBased) { return context.steps[zeroBased] }
        }
        return context.steps.first(where: { $0.outputs.contains(where: { $0.name == name }) })
    }

    private static func consumerSteps(for name: String, context: CaseInspectionContext) -> [SpecStep] {
        if let consumerIndices = context.consumerMap[name], !consumerIndices.isEmpty {
            var result: [SpecStep] = []
            var seen = Set<Int>()
            for rawIndex in consumerIndices {
                let matches = context.steps.filter { $0.number == rawIndex || $0.id == rawIndex }
                for step in matches where seen.insert(step.id).inserted { result.append(step) }
                if context.steps.indices.contains(rawIndex) {
                    let step = context.steps[rawIndex]
                    if seen.insert(step.id).inserted { result.append(step) }
                }
                let zeroBased = rawIndex - 1
                if context.steps.indices.contains(zeroBased) {
                    let step = context.steps[zeroBased]
                    if seen.insert(step.id).inserted { result.append(step) }
                }
            }
            if !result.isEmpty { return result.sorted { $0.number < $1.number } }
        }
        return context.steps
            .filter { $0.inputItems.contains(where: { $0.name == name }) }
            .sorted { $0.number < $1.number }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
