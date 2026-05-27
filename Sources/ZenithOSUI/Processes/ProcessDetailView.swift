import SwiftUI

// MARK: - Root

struct ProcessDetailView: View {
    let processCase: ProcessCase
    @ObservedObject var store: CaseStore

    @State private var spec: ProcessSpec? = nil
    @State private var specError: String? = nil
    @State private var rawProcessMarkdown: String? = nil
    @State private var rawProcessSourceURL: URL? = nil
    @State private var expandedDocument: MarkdownDocumentSource? = nil
    @AppStorage(HubArtifactMount.userDefaultsKey) private var hubArtifactMountsJSON: String = "[]"
    @AppStorage(HubRemoteAccess.localRootUserDefaultsKey) private var hubPathRoot: String = ""

    private let gatewayBase = ProcessInfo.processInfo.environment["GATEWAY_HTTP_URL"]
        ?? "http://localhost:8080"

    // Fallback: known process_name → gateway path (for cases created before Frank set process_path)
    private let nameToPath: [String: String] = [
        "review_submitted": "process-queued-review",
    ]

    var body: some View {
        ZStack {
            Group {
                if let contract = store.detail?.contract {
                    ProcessContractView(
                        contract: contract,
                        processCase: processCase,
                        detail: store.detail,
                        rawProcessMarkdown: rawProcessMarkdown,
                        rawProcessSourceURL: rawProcessSourceURL,
                        streamMode: store.detailStreamMode,
                        gatewayBase: gatewayBase,
                        artifactContentBaseURL: store.artifactContentBaseURL,
                        usesAdminArtifactAccess: store.usesAdminArtifactAccess,
                        onExpandDocument: { expandedDocument = $0 }
                    )
                } else if let spec {
                    ProcessSpecView(
                        spec: spec,
                        processCase: processCase,
                        detail: store.detail,
                        rawProcessMarkdown: rawProcessMarkdown,
                        rawProcessSourceURL: rawProcessSourceURL,
                        streamMode: store.detailStreamMode,
                        gatewayBase: gatewayBase,
                        artifactContentBaseURL: store.artifactContentBaseURL,
                        usesAdminArtifactAccess: store.usesAdminArtifactAccess,
                        onExpandDocument: { expandedDocument = $0 }
                    )
                } else if let err = specError {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.questionmark")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                        Text("Could not load process spec")
                            .font(.headline)
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView("Loading process…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            if let expandedDocument {
                ProcessMarkdownOverlay(
                    document: expandedDocument,
                    onDismiss: { self.expandedDocument = nil }
                )
                .zIndex(10)
            }
        }
        .navigationTitle(processCase.displayTitle)
        .onExitCommand {
            if expandedDocument != nil {
                expandedDocument = nil
            }
        }
        .task(id: processCase.id) {
            await store.startDetailMonitoring(for: processCase.id)
            await loadRawProcessSource()
            if store.detail?.contract == nil {
                await loadSpec()
            } else {
                spec = nil
                specError = nil
            }
        }
        .onDisappear {
            store.stopDetailMonitoring(for: processCase.id)
        }
    }

    private func loadSpec() async {
        spec = nil
        specError = nil

        if rawProcessMarkdown == nil {
            await loadRawProcessSource()
        }

        if let source = rawProcessMarkdown, !source.isEmpty {
            spec = ProcessSpecParser.parse(source)
            return
        }

        specError = "No process spec associated with this case"
    }

    private func loadRawProcessSource() async {
        rawProcessMarkdown = nil
        rawProcessSourceURL = nil

        let path = resolvedProcessPath
        let localURL = path.flatMap(localProcessURL(for:))
        rawProcessSourceURL = localURL

        if let path {
            if await loadRawProcessSourceFromHubFS(path: path) {
                return
            }
        }

        if let source = processCase.processSource, !source.isEmpty {
            rawProcessMarkdown = source
            return
        }

        if let path {
            for baseURL in processSpecEndpointBaseURLs() {
                if await loadRawProcessSourceFromProcessEndpoint(path: path, baseURL: baseURL) {
                    return
                }
            }
        }

        if let localURL {
            rawProcessMarkdown = try? String(contentsOf: localURL, encoding: .utf8)
        }
    }

    private func processSpecEndpointBaseURLs() -> [URL] {
        var urls: [URL] = []
        if store.usesAdminArtifactAccess, let hubBaseURL = store.artifactContentBaseURL {
            urls.append(hubBaseURL)
        }
        if let gatewayURL = URL(string: gatewayBase) {
            urls.append(gatewayURL)
        }
        return urls.reduce(into: []) { unique, url in
            if !unique.contains(url) {
                unique.append(url)
            }
        }
    }

    private func loadRawProcessSourceFromProcessEndpoint(path: String, baseURL: URL) async -> Bool {
        guard !path.contains("/") else { return false }
        let url = baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("processes")
            .appendingPathComponent(path)
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return false
            }
            if let json = try? JSONDecoder().decode([String: String].self, from: data),
               let content = json["content"], !content.isEmpty {
                rawProcessMarkdown = content
                rawProcessSourceURL = url
                return true
            }
        } catch {}
        return false
    }

    private func loadRawProcessSourceFromHubFS(path: String) async -> Bool {
        let mounts = HubRemoteAccess.mappings(from: hubArtifactMountsJSON, rootPath: hubPathRoot)
        guard let runtimePath = processDocumentRuntimePath(from: path),
              let reference = HubArtifactMirror.mirrorFileReference(
                  runtimePath: runtimePath,
                  baseURL: store.artifactContentBaseURL,
                  usesAdminArtifactAccess: store.usesAdminArtifactAccess,
                  mounts: mounts,
                  previewKind: .markdown,
                  sourceLabel: "process document HubFS path"
              ) else { return false }

        rawProcessSourceURL = reference.artifactContentURL
        do {
            let result = try await HubArtifactMirror.materializeIfPossible(reference: reference)
            guard let markdown = String(data: result.data, encoding: .utf8), !markdown.isEmpty else {
                return false
            }
            rawProcessMarkdown = markdown
            rawProcessSourceURL = result.localURL ?? reference.artifactContentURL
            return true
        } catch {
            specError = error.localizedDescription
            return false
        }
    }

    private func processDocumentRuntimePath(from rawPath: String) -> String? {
        let extracted = structurallyExtractProcessPath(from: rawPath) ?? rawPath
        var trimmed = extracted
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !trimmed.isEmpty else { return nil }

        let withoutFragment = trimmed.split(separator: "#", maxSplits: 1).first.map(String.init) ?? trimmed
        trimmed = withoutFragment.removingPercentEncoding ?? withoutFragment

        if trimmed.hasPrefix("file://"), let url = URL(string: trimmed) {
            trimmed = url.path
        } else if trimmed.hasPrefix("file:") {
            trimmed = String(trimmed.dropFirst(5))
        } else if trimmed.hasPrefix("dir:") {
            trimmed = String(trimmed.dropFirst(4))
        }

        return HubFSPath.normalize(trimmed)
    }

    private func structurallyExtractProcessPath(from raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return extractProcessPath(from: value)
    }

    private func extractProcessPath(from value: Any) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let object = value as? [String: Any] {
            for key in ["path", "process_path", "processPath", "file_path", "filepath", "url", "uri", "href", "source", "source_path"] {
                if let extracted = object[key].flatMap({ extractProcessPath(from: $0) }) {
                    return extracted
                }
            }
        }
        if let array = value as? [Any] {
            for item in array {
                if let extracted = extractProcessPath(from: item) {
                    return extracted
                }
            }
        }
        return nil
    }

    private var resolvedProcessPath: String? {
        processCase.processPath.flatMap { $0.isEmpty ? nil : $0 }
            ?? nameToPath[processCase.processName ?? ""]
    }

    private func localProcessURL(for path: String) -> URL? {
        let candidate = FileStore.hubRoot
            .appendingPathComponent("ops/processes/\(path).md")
            .resolvingSymlinksInPath()
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }
}

private func liveStatus(for step: SpecStep, detail: CaseDetailResponse?) -> String? {
    derivedStepStatus(for: step, detail: detail)
}

private func stepSlotLookup(for detail: CaseDetailResponse?) -> [String: ProcessSlot] {
    Dictionary(uniqueKeysWithValues: (detail?.slots ?? []).map { ($0.name, $0) })
}

private func normalizedStepStatus(_ raw: String?) -> String? {
    guard let raw, !raw.isEmpty else { return nil }
    switch raw.uppercased() {
    case "SUCCESS", "COMPLETE", "COMPLETED":
        return "COMPLETED"
    case "ERROR", "FAILED":
        return "FAILED"
    case "RUNNING", "IN_PROGRESS":
        return "IN_PROGRESS"
    case "READY":
        return "READY"
    case "BLOCKED":
        return "BLOCKED"
    case "PENDING":
        return "PENDING"
    default:
        return raw.uppercased()
    }
}

private func derivedStepStatus(for step: SpecStep, detail: CaseDetailResponse?) -> String? {
    let slotLookup = stepSlotLookup(for: detail)
    let processStep = detail?.steps.first(where: { $0.idx == step.number - 1 })
    let persisted = normalizedStepStatus(processStep?.status)
    let runtime = normalizedStepStatus(processStep?.runtimeStatus)

    if runtime == "FAILED" || persisted == "FAILED" {
        return "FAILED"
    }

    if runtime == "IN_PROGRESS" || persisted == "IN_PROGRESS" {
        return "IN_PROGRESS"
    }

    if !step.outputs.isEmpty,
       step.outputs.allSatisfy({ slotLookup[$0.name]?.isFilled == true }) {
        return "COMPLETED"
    }

    if runtime == "COMPLETED" || persisted == "COMPLETED" {
        return "COMPLETED"
    }

    let inputsReady = step.inputItems.allSatisfy { slotLookup[$0.name]?.isFilled == true }
    if inputsReady {
        return "READY"
    }

    if runtime == "BLOCKED" || persisted == "BLOCKED" {
        return "BLOCKED"
    }

    if let persisted, persisted != "PENDING" {
        return persisted
    }

    return nil
}

private func isActive(_ step: SpecStep, detail: CaseDetailResponse?, caseStatus: String) -> Bool {
    if let live = liveStatus(for: step, detail: detail) {
        return live == "READY" || live == "RUNNING" || live == "IN_PROGRESS"
    }
    if ["OPEN", "READY", "IN_PROGRESS"].contains(caseStatus), step.number == 1, detail?.steps.isEmpty != false {
        return true
    }
    return false
}

private func normalizedDisplaySteps(_ steps: [SpecStep]) -> [SpecStep] {
    var seenNumbers = Set<Int>()
    var normalized: [SpecStep] = []
    for step in steps {
        guard seenNumbers.insert(step.number).inserted else { continue }
        normalized.append(step)
    }
    return normalized
}

private func producerMap(from steps: [SpecStep]) -> [String: Int] {
    var map: [String: Int] = [:]
    for step in steps {
        for output in step.outputs where map[output.name] == nil {
            map[output.name] = step.number
        }
    }
    return map
}

private func consumerMap(from steps: [SpecStep]) -> [String: [Int]] {
    var map: [String: [Int]] = [:]
    for step in steps {
        for input in step.inputItems {
            map[input.name, default: []].append(step.number)
        }
    }
    return map
}

private let processSidebarWidth: CGFloat = 360

// MARK: - Main split layout

private struct ProcessSpecView: View {
    let spec: ProcessSpec
    let processCase: ProcessCase
    let detail: CaseDetailResponse?
    let rawProcessMarkdown: String?
    let rawProcessSourceURL: URL?
    let streamMode: CaseDetailStreamMode
    let gatewayBase: String
    let artifactContentBaseURL: URL?
    let usesAdminArtifactAccess: Bool
    let onExpandDocument: (MarkdownDocumentSource) -> Void
    @State private var hoveredStepIndex: Int? = nil
    @State private var hoveredInspectionTarget: CaseInspectionSelection? = nil
    @State private var pinnedInspectionTarget: CaseInspectionSelection? = .overview
    @AppStorage(HubArtifactMount.userDefaultsKey) private var hubArtifactMountsJSON: String = "[]"
    @AppStorage(HubRemoteAccess.localRootUserDefaultsKey) private var hubPathRoot: String = ""

    private var displaySteps: [SpecStep] {
        normalizedDisplaySteps(spec.steps)
    }

    private var inspectionContext: CaseInspectionContext {
        let producerMap = producerMap(from: displaySteps)
        let roots = CaseInspectionModel.fallbackRootInputs(steps: displaySteps, producerMap: producerMap)
        return CaseInspectionContext(
            processCase: processCase,
            detail: detail,
            steps: displaySteps,
            variables: spec.variables,
            rootInputs: roots,
            producerMap: producerMap,
            consumerMap: consumerMap(from: displaySteps),
            rawProcessMarkdown: rawProcessMarkdown,
            rawProcessSourceURL: rawProcessSourceURL,
            artifactMounts: HubRemoteAccess.mappings(from: hubArtifactMountsJSON, rootPath: hubPathRoot),
            artifactContentBaseURL: artifactContentBaseURL,
            usesAdminArtifactAccess: usesAdminArtifactAccess
        )
    }

    var body: some View {
        CaseInspectionOverlayHost(
            pinnedSelection: $pinnedInspectionTarget,
            context: inspectionContext,
            streamMode: streamMode,
            onSelect: { pinnedInspectionTarget = $0 }
        ) {
            HStack(alignment: .top, spacing: 0) {
                CaseInspectionSidebar(
                    title: spec.title,
                    subtitle: spec.description,
                    context: inspectionContext,
                    streamMode: streamMode,
                    selection: $pinnedInspectionTarget,
                    onExpandDocument: onExpandDocument,
                    processDocument: processDocument(title: spec.title)
                ) {
                    ProcessStatusRow(status: processCase.status)
                    if let detail {
                        DispatchSummaryCard(detail: detail)
                        SlotStatusSummaryCard(slots: detail.slots)
                    }
                    CaseRetryActions(status: processCase.status, caseID: processCase.id, gatewayBase: gatewayBase)
                }

            Divider()

            // Center panel — DAG
            DagGraphView(
                steps: displaySteps,
                variables: spec.variables,
                slots: detail?.slots ?? [],
                rootInputs: [],
                detail: detail,
                caseStatus: processCase.status,
                inspectionContext: inspectionContext,
                hoveredInspectionTarget: $hoveredInspectionTarget,
                pinnedInspectionTarget: $pinnedInspectionTarget,
                hoveredStepIndex: $hoveredStepIndex
            )
            }
        }
    }

    // MARK: - Left panel content

    @ViewBuilder
    private var leftPanel: some View {
        // Title + description
        VStack(alignment: .leading, spacing: 6) {
            Text(spec.title)
                .font(.headline)
            WhenToUseCard(
                summary: spec.description,
                document: processDocument(title: spec.title),
                onExpandDocument: onExpandDocument
            )
        }

        // Status badge
        ProcessStatusRow(status: processCase.status)

        if let detail {
            DispatchSummaryCard(detail: detail)
            SlotStatusSummaryCard(slots: detail.slots)
        }

        CaseRetryActions(status: processCase.status, caseID: processCase.id, gatewayBase: gatewayBase)

        // Constants
        if spec.steps.contains(where: { !$0.inputItems.isEmpty }) {
            ConstantsBox(steps: spec.steps, slots: detail?.slots ?? [])
        }

        // Steps (compact)
        StepListCard {
            ForEach(displaySteps.indices, id: \.self) { index in
                let step = displaySteps[index]
                StepCard(
                    step: step,
                    stepIndex: index,
                    liveStatus: liveStatus(for: step, detail: detail),
                    isActive: isActive(step, detail: detail, caseStatus: processCase.status),
                    compact: true,
                    isSelected: pinnedInspectionTarget == .selectionForStep(arrayIndex: index, step: step),
                    onSelect: { pinnedInspectionTarget = .selectionForStep(arrayIndex: index, step: step) },
                    onSelectSlot: { slotName in pinnedInspectionTarget = .slot(name: slotName) },
                    onHoverSelectionChanged: { hovering in
                        hoveredInspectionTarget = hovering ? .selectionForStep(arrayIndex: index, step: step) : nil
                    },
                    hoveredStepIndex: $hoveredStepIndex
                )
                if index < displaySteps.count - 1 {
                    Divider().padding(.leading, 16)
                }
            }
        }
    }

    private func processDocument(title: String) -> MarkdownDocumentSource? {
        guard let rawProcessMarkdown, !rawProcessMarkdown.isEmpty else { return nil }
        return MarkdownDocumentSource(
            title: title,
            markdown: rawProcessMarkdown,
            sourceURL: rawProcessSourceURL,
            context: .process
        )
    }
}

private struct ProcessContractView: View {
    let contract: ProcessContract
    let processCase: ProcessCase
    let detail: CaseDetailResponse?
    let rawProcessMarkdown: String?
    let rawProcessSourceURL: URL?
    let streamMode: CaseDetailStreamMode
    let gatewayBase: String
    let artifactContentBaseURL: URL?
    let usesAdminArtifactAccess: Bool
    let onExpandDocument: (MarkdownDocumentSource) -> Void
    @State private var hoveredStepIndex: Int? = nil
    @State private var hoveredInspectionTarget: CaseInspectionSelection? = nil
    @State private var pinnedInspectionTarget: CaseInspectionSelection? = .overview
    @AppStorage(HubArtifactMount.userDefaultsKey) private var hubArtifactMountsJSON: String = "[]"
    @AppStorage(HubRemoteAccess.localRootUserDefaultsKey) private var hubPathRoot: String = ""

    private var displaySteps: [SpecStep] {
        normalizedDisplaySteps(contract.steps)
    }

    private var inspectionContext: CaseInspectionContext {
        CaseInspectionContext(
            processCase: processCase,
            detail: detail,
            steps: displaySteps,
            variables: contract.variables,
            rootInputs: contract.rootInputs,
            producerMap: contract.producerMap,
            consumerMap: contract.consumerMap,
            rawProcessMarkdown: rawProcessMarkdown,
            rawProcessSourceURL: rawProcessSourceURL,
            artifactMounts: HubRemoteAccess.mappings(from: hubArtifactMountsJSON, rootPath: hubPathRoot),
            artifactContentBaseURL: artifactContentBaseURL,
            usesAdminArtifactAccess: usesAdminArtifactAccess
        )
    }

    private var slotLookup: [String: ProcessSlot] {
        Dictionary(uniqueKeysWithValues: (detail?.slots ?? []).map { ($0.name, $0) })
    }

    private func isReady(_ step: SpecStep) -> Bool {
        liveStatus(for: step, detail: detail) == "READY"
    }

    var body: some View {
        CaseInspectionOverlayHost(
            pinnedSelection: $pinnedInspectionTarget,
            context: inspectionContext,
            streamMode: streamMode,
            onSelect: { pinnedInspectionTarget = $0 }
        ) {
            HStack(alignment: .top, spacing: 0) {
            CaseInspectionSidebar(
                title: contract.title,
                subtitle: contract.description,
                context: inspectionContext,
                streamMode: streamMode,
                selection: $pinnedInspectionTarget,
                onExpandDocument: onExpandDocument,
                processDocument: processDocument(title: contract.title)
            ) {
                ProcessStatusRow(status: processCase.status)
                if let detail {
                    DispatchSummaryCard(detail: detail)
                    SlotStatusSummaryCard(slots: detail.slots)
                }
                CaseRetryActions(status: processCase.status, caseID: processCase.id, gatewayBase: gatewayBase)
            }

            Divider()

            DagGraphView(
                steps: displaySteps,
                variables: contract.variables,
                slots: detail?.slots ?? [],
                rootInputs: contract.rootInputs,
                detail: detail,
                caseStatus: processCase.status,
                inspectionContext: inspectionContext,
                hoveredInspectionTarget: $hoveredInspectionTarget,
                pinnedInspectionTarget: $pinnedInspectionTarget,
                hoveredStepIndex: $hoveredStepIndex
            )
            }
        }
    }

    @ViewBuilder
    private var leftPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(contract.title)
                .font(.headline)
            WhenToUseCard(
                summary: contract.description,
                document: processDocument(title: contract.title),
                onExpandDocument: onExpandDocument
            )
        }

        ProcessStatusRow(status: processCase.status)

        if let detail {
            DispatchSummaryCard(detail: detail)
            SlotStatusSummaryCard(slots: detail.slots)
        }

        CaseRetryActions(status: processCase.status, caseID: processCase.id, gatewayBase: gatewayBase)

        // Variables — shown above steps, updates live as slots are filled
        if !(detail?.slots ?? []).isEmpty {
            ConstantsBox(steps: displaySteps, slots: detail?.slots ?? [])
        }

        StepListCard {
            ForEach(displaySteps.indices, id: \.self) { index in
                let step = displaySteps[index]
                StepCard(
                    step: step,
                    stepIndex: index,
                    liveStatus: liveStatus(for: step, detail: detail),
                    isActive: isActive(step, detail: detail, caseStatus: processCase.status),
                    isReady: isReady(step),
                    slotLookup: slotLookup,
                    compact: true,
                    isSelected: pinnedInspectionTarget == .selectionForStep(arrayIndex: index, step: step),
                    onSelect: { pinnedInspectionTarget = .selectionForStep(arrayIndex: index, step: step) },
                    onSelectSlot: { slotName in pinnedInspectionTarget = .slot(name: slotName) },
                    onHoverSelectionChanged: { hovering in
                        hoveredInspectionTarget = hovering ? .selectionForStep(arrayIndex: index, step: step) : nil
                    },
                    hoveredStepIndex: $hoveredStepIndex
                )
                if index < displaySteps.count - 1 {
                    Divider().padding(.leading, 16)
                }
            }
        }
    }

    private func processDocument(title: String) -> MarkdownDocumentSource? {
        guard let rawProcessMarkdown, !rawProcessMarkdown.isEmpty else { return nil }
        return MarkdownDocumentSource(
            title: title,
            markdown: rawProcessMarkdown,
            sourceURL: rawProcessSourceURL,
            context: .process
        )
    }
}

// MARK: - Rerun Button

private struct CaseRetryActions: View {
    let status: String
    let caseID: String
    let gatewayBase: String

    private var normalizedStatus: String { status.uppercased() }
    private var canFollowUp: Bool { normalizedStatus == "BLOCKED" }
    private var canRerun: Bool { ["COMPLETE", "COMPLETED", "FAILED"].contains(normalizedStatus) }
    private var canForceRetry: Bool { ["BLOCKED", "FAILED", "COMPLETE", "COMPLETED"].contains(normalizedStatus) }

    var body: some View {
        if canFollowUp || canRerun || canForceRetry {
            HStack(spacing: 8) {
                if canFollowUp {
                    FollowUpButton(caseID: caseID, gatewayBase: gatewayBase)
                }
                if canRerun {
                    RerunButton(caseID: caseID, gatewayBase: gatewayBase)
                }
                if canForceRetry {
                    RerunButton(caseID: caseID, gatewayBase: gatewayBase, force: true)
                }
            }
        }
    }
}

private struct FollowUpButton: View {
    let caseID: String
    let gatewayBase: String
    @State private var isPresented = false
    @State private var note = ""
    @State private var state: FollowUpState = .idle

    enum FollowUpState: Equatable { case idle, submitting, queued, failed(String) }

    var body: some View {
        Button(action: { isPresented = true }) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble")
                Text("Follow Up")
            }
            .font(.subheadline)
        }
        .buttonStyle(.borderedProminent)
        .help("Submit operator input for this blocked case and retry it")
        .sheet(isPresented: $isPresented) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Operator Follow Up")
                    .font(.headline)
                Text("Add the missing context or instruction needed to unblock this case. Submitting records it in the case log and re-enqueues the case.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $note)
                    .font(.body.monospaced())
                    .frame(width: 460, height: 180)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.25))
                    )
                if case .failed(let message) = state {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { isPresented = false }
                        .disabled(state == .submitting)
                    Button(action: submit) {
                        switch state {
                        case .submitting:
                            ProgressView().controlSize(.small)
                        case .queued:
                            Label("Queued", systemImage: "checkmark")
                        default:
                            Label("Submit & Retry", systemImage: "paperplane")
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state == .submitting || state == .queued)
                }
            }
            .padding(20)
        }
    }

    private func submit() {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        state = .submitting
        Task {
            do {
                guard let url = URL(string: "\(gatewayBase)/v1/cases/\(caseID)/follow-up") else { return }
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: [
                    "note": trimmed,
                    "operator": NSFullUserName().isEmpty ? "ZenithOS" : NSFullUserName(),
                    "force_retry": true,
                ])
                let (_, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    state = .queued
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    isPresented = false
                    note = ""
                    state = .idle
                } else {
                    state = .failed("Server rejected the follow-up")
                }
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}

private struct RerunButton: View {
    let caseID: String
    let gatewayBase: String
    var force: Bool = false
    @State private var state: RerunState = .idle

    enum RerunState: Equatable { case idle, running, queued, failed(String) }

    var body: some View {
        Button(action: rerun) {
            HStack(spacing: 6) {
                switch state {
                case .idle:
                    Image(systemName: force ? "exclamationmark.arrow.triangle.2.circlepath" : "arrow.clockwise")
                    Text(force ? "Force retry" : "Rerun")
                case .running:
                    ProgressView().controlSize(.small)
                    Text("Queuing…")
                case .queued:
                    Image(systemName: "checkmark")
                    Text("Queued")
                case .failed:
                    Image(systemName: "exclamationmark.triangle")
                    Text("Failed")
                }
            }
            .font(.subheadline)
        }
        .buttonStyle(.bordered)
        .disabled(state == .running || state == .queued)
        .help(helpText)
    }

    private var helpText: String {
        if case .failed(let msg) = state { return msg }
        if force { return "Force re-enqueue this case even if it is blocked" }
        return "Re-enqueue this case and watch it run again"
    }

    private func rerun() {
        state = .running
        Task {
            do {
                let suffix = force ? "?force=true" : ""
                guard let url = URL(string: "\(gatewayBase)/v1/cases/\(caseID)/rerun\(suffix)") else { return }
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                let (_, resp) = try await URLSession.shared.data(for: req)
                if (resp as? HTTPURLResponse)?.statusCode == 200 {
                    state = .queued
                    // Reset to idle after 3s so user can rerun again if needed
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    state = .idle
                } else {
                    state = .failed("Server returned an error")
                }
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}

private struct ProcessStatusRow: View {
    let status: String

    var body: some View {
        HStack {
            CaseStatusBadge(status: status)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var subtitle: String {
        switch status {
        case "OPEN": return "awaiting assignment"
        case "READY": return "queued for worker"
        case "IN_PROGRESS": return "worker accepted"
        case "BLOCKED": return "waiting on input"
        case "COMPLETED", "COMPLETE": return "finished"
        case "FAILED": return "failed"
        default: return status.lowercased()
        }
    }
}

private struct SlotStatusSummaryCard: View {
    let slots: [ProcessSlot]

    private var statusSlot: ProcessSlot? {
        slots.first { $0.name.lowercased().hasSuffix("_status") || $0.name.lowercased() == "status" }
    }

    private var pathSlot: ProcessSlot? {
        slots.first { $0.name.lowercased().hasSuffix("_path") || $0.name.lowercased().hasSuffix("_url") }
    }

    private var status: String? {
        guard let statusSlot else { return nil }
        return decodedValue(statusSlot)
    }

    private var pathValue: String? {
        guard let pathSlot else { return nil }
        return decodedValue(pathSlot)
    }

    var body: some View {
        if let status, let statusSlot {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(color(for: status))
                        .frame(width: 8, height: 8)
                    Text(displayTitle(for: statusSlot.name))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(label(for: status))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(color(for: status))
                }
                if let pathValue, !pathValue.isEmpty {
                    Text(pathValue)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(color(for: status).opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(color(for: status).opacity(0.18), lineWidth: 1)
            )
        }
    }

    private func decodedValue(_ slot: ProcessSlot) -> String? {
        guard let raw = slot.value, !raw.isEmpty else { return nil }
        if let data = raw.data(using: .utf8),
           let value = try? JSONSerialization.jsonObject(with: data) as? String {
            return value
        }
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    private func displayTitle(for name: String) -> String {
        name
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    private func label(for status: String) -> String {
        status.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func color(for status: String) -> Color {
        let normalized = status.lowercased()
        if normalized.contains("ready") || normalized.contains("complete") || normalized.contains("success") {
            return .green
        }
        if normalized.contains("fail") || normalized.contains("error") {
            return .red
        }
        return .orange
    }
}

private struct WhenToUseCard: View {
    let summary: String
    let document: MarkdownDocumentSource?
    let onExpandDocument: (MarkdownDocumentSource) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("When to use")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("View") {
                    guard let document else { return }
                    onExpandDocument(document)
                }
                .buttonStyle(.link)
                .disabled(document == nil)
            }

            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

@MainActor
private struct ProcessMarkdownOverlay: View {
    let document: MarkdownDocumentSource
    let onDismiss: () -> Void
    @StateObject private var session: MarkdownReaderSession
    init(document: MarkdownDocumentSource, onDismiss: @escaping () -> Void) {
        self.document = document
        self.onDismiss = onDismiss
        self._session = StateObject(
            wrappedValue: MarkdownReaderSession(
                initialDocument: document,
                linkResolver: MarkdownLinkNavigator.makeResolver(context: .process)
            )
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let width = min(820, geometry.size.width - 80)
            let height = max(geometry.size.height - 64, 420)

            ZStack {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture(perform: onDismiss)

                MarkdownReaderView(
                    session: session,
                    presentationMode: .processModal
                )
                .frame(width: width, height: height)
                // CSS owns the white background; clip only bounds the WKWebView to the card shape
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(alignment: .topLeading) {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                            .frame(width: 30, height: 30)
                            .background(
                                Circle()
                                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.96))
                            )
                            .overlay(
                                Circle()
                                    .stroke(Color.white.opacity(0.85), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .offset(x: -5, y: -5)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: document.id) {
            session.setDocument(document, resetHistory: true)
        }
    }
}

private struct StepListCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Constants box

private struct ConstantEntry {
    let name: String
    let setByStep: Int?       // nil = dispatcher provides it; N = Step N produces it
    let neededBySteps: [Int]  // step numbers that use this variable
    let slot: ProcessSlot?    // live fill state, if any

    var isFilled: Bool { slot?.isFilled ?? false }

    var hoverText: String {
        let setter: String
        if let n = setByStep {
            setter = "Set by Step \(n)"
        } else {
            let first = neededBySteps.first.map { "Step \($0)" } ?? "any step"
            setter = "Must be provided by dispatcher before \(first)"
        }
        let needed = neededBySteps.map { "Step \($0)" }.joined(separator: ", ")
        return "\(setter) · Needed by: \(needed)"
    }
}

private func buildConstantEntries(steps: [SpecStep], slots: [ProcessSlot]) -> [ConstantEntry] {
    var firstSeen: [String: Int] = [:]    // name → step number where first seen as input
    var neededBy:  [String: [Int]] = [:]  // name → all step numbers that need it

    for step in steps {
        for item in step.inputItems {
            if firstSeen[item.name] == nil {
                firstSeen[item.name] = step.number
            }
            neededBy[item.name, default: []].append(step.number)
        }
    }

    var slotLookup: [String: ProcessSlot] = [:]
    for slot in slots { slotLookup[slot.name] = slot }

    return firstSeen.keys
        .sorted { (firstSeen[$0] ?? 0, $0) < (firstSeen[$1] ?? 0, $1) }
        .map { name in
            let first = firstSeen[name]!
            let setBy = first == 1 ? nil : first - 1
            return ConstantEntry(
                name: name,
                setByStep: setBy,
                neededBySteps: neededBy[name] ?? [],
                slot: slotLookup[name]
            )
        }
}

private struct ConstantsBox: View {
    let steps: [SpecStep]
    let slots: [ProcessSlot]

    private var entries: [ConstantEntry] { buildConstantEntries(steps: steps, slots: slots) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("CONSTANTS")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)
                .padding(.horizontal, 6)
                .padding(.bottom, 2)

            ForEach(entries, id: \.name) { entry in
                ConstantRow(entry: entry)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ConstantRow: View {
    let entry: ConstantEntry
    @State private var isShowing = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(entry.isFilled ? Color.green : Color.secondary.opacity(0.22))
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(entry.isFilled ? .primary : .tertiary)
                    .lineLimit(1)
                // Show value inline as it arrives — first line, truncated
                if entry.isFilled, let val = entry.slot?.value, !val.isEmpty {
                    Text(val.prefix(60).replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            Spacer(minLength: 0)
            Group {
                if entry.isFilled {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "circle.dashed")
                        .foregroundStyle(.quaternary)
                }
            }
            .font(.system(size: 10))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(isShowing ? Color.accentColor.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .onHover { hovering in
            if hovering {
                hoverTask?.cancel()
                hoverTask = Task { @MainActor in
                    do {
                        try await Task.sleep(nanoseconds: 700_000_000)
                        isShowing = true
                    } catch {}
                }
            } else {
                hoverTask?.cancel()
                isShowing = false
            }
        }
        .popover(isPresented: $isShowing, arrowEdge: .trailing) {
            ConstantDetailView(entry: entry)
        }
    }
}

private struct ConstantDetailView: View {
    let entry: ConstantEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            HStack(spacing: 8) {
                Circle()
                    .fill(entry.isFilled ? Color.green : Color.secondary.opacity(0.28))
                    .frame(width: 8, height: 8)
                Text(entry.name)
                    .font(.system(.callout, design: .monospaced).weight(.medium))
                    .lineLimit(1)
                Spacer()
                if entry.isFilled {
                    Label("set", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.green)
                } else {
                    Label("pending", systemImage: "clock")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider().opacity(0.5)

            // Provenance
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: entry.setByStep == nil ? "person.badge.key.fill" : "arrow.up.right.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(entry.setByStep == nil ? Color.accentColor : .secondary)
                        .frame(width: 16, alignment: .center)
                        .padding(.top, 1)
                    if let step = entry.setByStep {
                        (Text("Set by ").foregroundColor(.secondary) +
                         Text("Step \(step)").foregroundColor(.primary).bold())
                            .font(.callout)
                    } else {
                        (Text("Provided by ").foregroundColor(.secondary) +
                         Text("dispatcher").foregroundColor(.accentColor).bold())
                            .font(.callout)
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("NEEDED BY")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .tracking(0.6)
                    HStack(spacing: 4) {
                        ForEach(entry.neededBySteps, id: \.self) { n in
                            Text("Step \(n)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(.quaternary)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            // Value (filled only)
            if let slot = entry.slot, entry.isFilled {
                Divider().opacity(0.5)
                VStack(alignment: .leading, spacing: 6) {
                    Text("VALUE")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .tracking(0.6)
                    ScrollView {
                        Text(slot.displayValue)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 100)
                    .padding(8)
                    .background(.quaternary.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
        .frame(width: 272)
    }
}

// MARK: - DAG

private struct DagGraphView: View {
    let steps: [SpecStep]
    let variables: [String: VariableMeta]
    let slots: [ProcessSlot]
    let rootInputs: [String]
    let detail: CaseDetailResponse?
    let caseStatus: String
    let inspectionContext: CaseInspectionContext
    @Binding var hoveredInspectionTarget: CaseInspectionSelection?
    @Binding var pinnedInspectionTarget: CaseInspectionSelection?
    @Binding var hoveredStepIndex: Int?
    @State private var selectedExecutionStepID: String? = nil

    private var liveStatuses: [Int: String] {
        var map: [Int: String] = [:]
        for step in steps {
            if let status = derivedStepStatus(for: step, detail: detail) {
                map[step.number - 1] = status
            }
        }
        return map
    }

    private var slotLookup: [String: ProcessSlot] {
        Dictionary(uniqueKeysWithValues: slots.map { ($0.name, $0) })
    }

    private var renderedEdges: [DagEdge] {
        let grouped = Dictionary(grouping: buildDataDagEdges(from: steps)) { DagEdgePair(from: $0.from, to: $0.to) }
        return grouped
            .keys
            .sorted { lhs, rhs in
                if lhs.from == rhs.from { return lhs.to < rhs.to }
                return lhs.from < rhs.from
            }
            .compactMap { grouped[$0]?.first }
    }

    private var runningSteps: [ProcessStep] {
        (detail?.steps ?? [])
            .filter(\.isRunning)
            .sorted { lhs, rhs in
                if lhs.idx == rhs.idx { return lhs.updatedAt > rhs.updatedAt }
                return lhs.idx < rhs.idx
            }
    }

    private var runningStepIDs: [String] {
        runningSteps.map(\.id)
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 16) {
                    if !rootInputs.isEmpty {
                        DispatcherInputsBar(
                            rootInputs: rootInputs,
                            variables: variables,
                            slots: slotLookup,
                            hoveredSelection: $hoveredInspectionTarget,
                            pinnedSelection: $pinnedInspectionTarget
                        )
                    }

                    Text("DAG")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                        .padding(.top, 20)

                    GeometryReader { graphProxy in
                        let containerHeight = max(260, proxy.size.height * 0.52)
                        let viewport = CGSize(
                            width: max(graphProxy.size.width - 24, 160),
                            height: max(containerHeight - 24, 160)
                        )
                        let layout = DagLayout.make(
                            steps: steps,
                            edges: renderedEdges,
                            viewportSize: viewport
                        )

                        let graphCanvas = ZStack(alignment: .topLeading) {
                            DagEdgeCanvas(
                                edges: renderedEdges,
                                layout: layout,
                                liveStatuses: liveStatuses,
                                caseStatus: caseStatus,
                                hoveredStepIndex: hoveredStepIndex
                            )

                            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                                if let center = layout.centers[index] {
                                    DagGraphNode(
                                        step: step,
                                        stepIndex: index,
                                        status: liveStatuses[step.number - 1],
                                        caseStatus: caseStatus,
                                        nodeRadius: layout.nodeRadius,
                                        hoveredStepIndex: hoveredStepIndex,
                                        isReady: liveStatuses[step.number - 1] == "READY",
                                        isSelected: pinnedInspectionTarget == .selectionForStep(arrayIndex: index, step: step),
                                        onSelect: {
                                            pinnedInspectionTarget = .selectionForStep(arrayIndex: index, step: step)
                                        },
                                        onHoverChanged: { hovering in
                                            hoveredStepIndex = hovering ? index : nil
                                            hoveredInspectionTarget = hovering ? .selectionForStep(arrayIndex: index, step: step) : nil
                                        }
                                    )
                                    .position(x: center.x, y: center.y)
                                }
                            }
                        }
                        .frame(width: layout.contentSize.width, height: layout.contentSize.height)

                        ZStack {
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .fill(Color(nsColor: .windowBackgroundColor))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                                        .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
                                )

                            if layout.requiresScrolling {
                                ScrollView([.horizontal, .vertical]) {
                                    graphCanvas
                                        .padding(12)
                                }
                            } else {
                                graphCanvas
                                    .padding(12)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: containerHeight)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                    .frame(height: max(260, proxy.size.height * 0.52))
                    .padding(.horizontal, 20)

                    ExecutionMonitorCard(
                        runningSteps: runningSteps,
                        specSteps: steps,
                        logs: detail?.logs ?? [],
                        selectedStepID: $selectedExecutionStepID
                    )
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .topLeading)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .onAppear(perform: syncSelectedExecution)
            .onChange(of: runningStepIDs) { _ in
                syncSelectedExecution()
            }
        }
    }

    private func syncSelectedExecution() {
        guard !runningSteps.isEmpty else {
            selectedExecutionStepID = nil
            return
        }
        if let selectedExecutionStepID,
           runningSteps.contains(where: { $0.id == selectedExecutionStepID }) {
            return
        }
        self.selectedExecutionStepID = runningSteps.first?.id
    }
}

private struct ExecutionMonitorCard: View {
    let runningSteps: [ProcessStep]
    let specSteps: [SpecStep]
    let logs: [ProcessLog]
    @Binding var selectedStepID: String?

    private var selectedStep: ProcessStep? {
        if let selectedStepID,
           let step = runningSteps.first(where: { $0.id == selectedStepID }) {
            return step
        }
        return runningSteps.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("EXECUTION")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.6)
                Spacer()
                if !runningSteps.isEmpty {
                    Text("\(runningSteps.count) active")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            if runningSteps.count > 1 {
                Picker("Running step", selection: $selectedStepID) {
                    ForEach(runningSteps, id: \.id) { step in
                        Text("Step \(step.idx + 1)")
                            .tag(Optional(step.id))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if let selectedStep {
                let specStep = specStep(for: selectedStep)
                let stepLogs = logsForStep(selectedStep)

                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Text(specStep?.title ?? selectedStep.name)
                                    .font(.headline)
                                StepStatusPill(status: selectedStep.status)
                            }

                            HStack(spacing: 8) {
                                ExecutionMetaChip(text: "Step \(selectedStep.idx + 1)")
                                if let executor = selectedStep.executor, !executor.isEmpty {
                                    ExecutionMetaChip(text: executor)
                                }
                                if let action = selectedStep.action, !action.isEmpty {
                                    ExecutionMetaChip(text: action)
                                }
                                if let timestamp = compactProcessTimestamp(selectedStep.updatedAt) {
                                    ExecutionMetaChip(text: timestamp)
                                }
                            }
                        }

                        Spacer(minLength: 0)
                    }

                    if let specStep, !specStep.instructions.isEmpty {
                        Text(specStep.instructions)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(alignment: .top, spacing: 12) {
                        if let args = prettyJSONString(selectedStep.argsJson) {
                            ExecutionPayloadPanel(title: "ARGS", content: args)
                        }
                        if let result = prettyJSONString(selectedStep.resultJson) {
                            ExecutionPayloadPanel(title: "RESULT", content: result)
                        }
                        if let runtime = selectedStep.runtimeDisplayValue {
                            ExecutionPayloadPanel(title: "RUNTIME", content: runtime)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("RECENT LOGS")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .tracking(0.6)

                        if stepLogs.isEmpty {
                            Text("No step logs yet.")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                        } else {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(stepLogs.prefix(10)) { log in
                                        ExecutionLogRow(log: log)
                                    }
                                }
                            }
                            .frame(maxHeight: 180)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No active executions")
                        .font(.headline)
                    Text("Running steps will appear here as soon as the case starts executing.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func specStep(for processStep: ProcessStep) -> SpecStep? {
        specSteps.first(where: { $0.number - 1 == processStep.idx })
    }

    private func logsForStep(_ processStep: ProcessStep) -> [ProcessLog] {
        logs
            .filter { $0.stepId == processStep.id }
            .sorted { $0.createdAt > $1.createdAt }
    }
}

private struct ExecutionMetaChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

private struct ExecutionPayloadPanel: View {
    let title: String
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.6)

            ScrollView {
                Text(content)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 88, maxHeight: 120)
            .padding(10)
            .background(.quaternary.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ExecutionLogRow: View {
    let log: ProcessLog
    @State private var showingMetadata = false

    private var metadata: String? {
        guard let metadata = log.metadataJson?.prettyPrintedString,
              !metadata.isEmpty,
              metadata != "null" else { return nil }
        return metadata
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let timestamp = compactProcessTimestamp(log.createdAt) {
                    Text(timestamp)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Text(log.type)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                if metadata != nil {
                    Image(systemName: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("Metadata available")
                }
            }

            Text(log.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.34))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering in
            showingMetadata = hovering && metadata != nil
        }
        .popover(isPresented: $showingMetadata, arrowEdge: .trailing) {
            if let metadata {
                ScrollView {
                    Text(metadata)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(width: 360)
                .frame(maxHeight: 260)
            }
        }
    }
}

private func prettyJSONString(_ raw: String?) -> String? {
    guard let raw, !raw.isEmpty else { return nil }
    guard let data = raw.data(using: .utf8) else { return raw }
    guard let object = try? JSONSerialization.jsonObject(with: data) else { return raw }
    guard let pretty = try? JSONSerialization.data(withJSONObject: object, options: .prettyPrinted),
          let string = String(data: pretty, encoding: .utf8) else { return raw }
    return string
}

private func compactProcessTimestamp(_ raw: String?) -> String? {
    guard let raw, !raw.isEmpty else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let basic = ISO8601DateFormatter()

    if let date = fractional.date(from: raw) ?? basic.date(from: raw) {
        return date.formatted(date: .abbreviated, time: .shortened)
    }
    return raw
}

private struct DagEdgePair: Hashable {
    let from: Int
    let to: Int
}

private func buildDataDagEdges(from steps: [SpecStep]) -> [DagEdge] {
    var edges: [DagEdge] = []
    for i in 0 ..< steps.count {
        let produced = Set(steps[i].outputs.map(\.name))
        for j in (i + 1) ..< steps.count {
            let consumed = Set(steps[j].inputItems.map(\.name))
            let shared = produced.intersection(consumed)
            guard !shared.isEmpty else { continue }
            let label = shared.sorted().first ?? ""
            edges.append(DagEdge(from: i, to: j, label: label, isSkip: j > i + 1))
        }
    }
    return edges
}

private struct DagEdgePorts {
    let fromOffset: CGFloat
    let toOffset: CGFloat
}

private struct DagLayoutMetrics {
    let nodeDiameter: CGFloat
    let columnGap: CGFloat
    let rowGap: CGFloat
    let requiredWidth: CGFloat
    let requiredHeight: CGFloat
    let requiresScrolling: Bool
}

private struct DagSourceFanKey: Hashable {
    let source: Int
    let targetLayer: Int
}

private struct DagSourceFan {
    let source: Int
    let targetLayer: Int
    let edges: [DagEdge]
}

private struct DagLayout {
    let centers: [Int: CGPoint]
    let contentSize: CGSize
    let nodeRadius: CGFloat
    let edgePorts: [DagEdgePair: DagEdgePorts]
    let requiresScrolling: Bool

    func geometry(for edge: DagEdge) -> DagEdgeGeometry? {
        guard let fromCenter = centers[edge.from], let toCenter = centers[edge.to] else {
            return nil
        }
        let pair = DagEdgePair(from: edge.from, to: edge.to)
        let ports = edgePorts[pair] ?? DagEdgePorts(fromOffset: 0, toOffset: 0)
        return DagEdgeGeometry(
            fromCenter: fromCenter,
            toCenter: toCenter,
            nodeRadius: nodeRadius,
            fromOffset: ports.fromOffset,
            toOffset: ports.toOffset
        )
    }

    static func make(
        steps: [SpecStep],
        edges: [DagEdge],
        viewportSize: CGSize
    ) -> DagLayout {
        guard !steps.isEmpty else {
            return DagLayout(
                centers: [:],
                contentSize: viewportSize,
                nodeRadius: 18,
                edgePorts: [:],
                requiresScrolling: false
            )
        }

        let uniqueEdges = Array(
            Dictionary(uniqueKeysWithValues: edges.map { (DagEdgePair(from: $0.from, to: $0.to), $0) }).values
        ).sorted { lhs, rhs in
            if lhs.from == rhs.from { return lhs.to < rhs.to }
            return lhs.from < rhs.from
        }

        let nodeCount = steps.count
        let depths = depthMap(nodeCount: nodeCount, edges: uniqueEdges)
        let layerCount = (depths.max() ?? 0) + 1
        let incomingEdges = Dictionary(grouping: uniqueEdges, by: \.to)
        let layers = orderedLayers(
            nodeCount: nodeCount,
            layerCount: layerCount,
            depths: depths,
            steps: steps
        )
        let sourceFans = buildSourceFans(edges: uniqueEdges, depths: depths, steps: steps)
        let maxLayerNodes = layers.map(\.count).max() ?? 1
        let metrics = selectMetrics(
            layerCount: layerCount,
            maxLayerNodes: maxLayerNodes,
            viewportSize: viewportSize
        )

        let contentSize = CGSize(
            width: metrics.requiresScrolling
                ? max(viewportSize.width, metrics.requiredWidth + 56)
                : viewportSize.width,
            height: metrics.requiresScrolling
                ? max(viewportSize.height, metrics.requiredHeight + 56)
                : viewportSize.height
        )
        let nodeRadius = metrics.nodeDiameter / 2
        let horizontalInset: CGFloat = 28 + nodeRadius
        let verticalInset: CGFloat = 28 + nodeRadius
        let minCenterGap = metrics.nodeDiameter + metrics.rowGap
        let maxCenterGap = max(minCenterGap, min(minCenterGap * 2.2, contentSize.height * 0.4))

        let xPositions = layerXPositions(
            layerCount: layerCount,
            contentWidth: contentSize.width,
            inset: horizontalInset
        )
        let layerGaps = layerCenterGaps(
            layers: layers,
            sourceFans: sourceFans,
            contentHeight: contentSize.height,
            inset: verticalInset,
            minCenterGap: minCenterGap,
            maxCenterGap: maxCenterGap
        )
        let yPositions = sourceDrivenLayerPositions(
            layers: layers,
            steps: steps,
            depths: depths,
            incomingEdges: incomingEdges,
            sourceFans: sourceFans,
            contentHeight: contentSize.height,
            inset: verticalInset,
            layerGaps: layerGaps
        )

        var centers: [Int: CGPoint] = [:]
        for layerIndex in layers.indices {
            for stepIndex in layers[layerIndex] {
                centers[stepIndex] = CGPoint(x: xPositions[layerIndex], y: yPositions[stepIndex])
            }
        }

        return DagLayout(
            centers: centers,
            contentSize: contentSize,
            nodeRadius: nodeRadius,
            edgePorts: buildEdgePorts(
                edges: uniqueEdges,
                centers: centers,
                nodeRadius: nodeRadius,
                depths: depths,
                steps: steps,
                sourceFans: sourceFans,
                layerGaps: layerGaps
            ),
            requiresScrolling: metrics.requiresScrolling
        )
    }

    private static func depthMap(nodeCount: Int, edges: [DagEdge]) -> [Int] {
        var incoming = Array(repeating: [Int](), count: nodeCount)
        for edge in edges where edge.from < nodeCount && edge.to < nodeCount {
            incoming[edge.to].append(edge.from)
        }

        var depths = Array(repeating: 0, count: nodeCount)
        for index in 0 ..< nodeCount {
            if let maxParentDepth = incoming[index].map({ depths[$0] }).max() {
                depths[index] = maxParentDepth + 1
            }
        }
        return depths
    }

    private static func orderedLayers(
        nodeCount: Int,
        layerCount: Int,
        depths: [Int],
        steps: [SpecStep]
    ) -> [[Int]] {
        (0 ..< layerCount).map { layer in
            (0 ..< nodeCount)
                .filter { depths[$0] == layer }
                .sorted { lhs, rhs in
                    compareStepOrder(lhs: lhs, rhs: rhs, steps: steps)
                }
        }
    }

    private static func selectMetrics(
        layerCount: Int,
        maxLayerNodes: Int,
        viewportSize: CGSize
    ) -> DagLayoutMetrics {
        let minDiameter = 24
        let maxDiameter = 44
        let widthAllowance = max(viewportSize.width - 56, 120)
        let heightAllowance = max(viewportSize.height - 56, 120)

        func makeMetrics(nodeDiameter: CGFloat) -> DagLayoutMetrics {
            let columnGap = clamp(nodeDiameter * 1.85, min: 34, max: 92)
            let rowGap = clamp(nodeDiameter * 1.35, min: 20, max: 72)
            let requiredWidth = CGFloat(layerCount) * nodeDiameter
                + CGFloat(max(layerCount - 1, 0)) * columnGap
            let requiredHeight = CGFloat(maxLayerNodes) * nodeDiameter
                + CGFloat(max(maxLayerNodes - 1, 0)) * rowGap
            let requiresScrolling = requiredWidth > widthAllowance || requiredHeight > heightAllowance
            return DagLayoutMetrics(
                nodeDiameter: nodeDiameter,
                columnGap: columnGap,
                rowGap: rowGap,
                requiredWidth: requiredWidth,
                requiredHeight: requiredHeight,
                requiresScrolling: requiresScrolling
            )
        }

        for diameter in stride(from: maxDiameter, through: minDiameter, by: -1) {
            let candidate = makeMetrics(nodeDiameter: CGFloat(diameter))
            if !candidate.requiresScrolling {
                return candidate
            }
        }

        return makeMetrics(nodeDiameter: CGFloat(minDiameter))
    }

    private static func layerXPositions(
        layerCount: Int,
        contentWidth: CGFloat,
        inset: CGFloat
    ) -> [CGFloat] {
        if layerCount <= 1 {
            return [contentWidth / 2]
        }
        let left = inset
        let right = contentWidth - inset
        let stride = (right - left) / CGFloat(layerCount - 1)
        return (0 ..< layerCount).map { left + CGFloat($0) * stride }
    }

    private static func buildSourceFans(
        edges: [DagEdge],
        depths: [Int],
        steps: [SpecStep]
    ) -> [DagSourceFanKey: DagSourceFan] {
        let grouped = Dictionary(grouping: edges) { edge in
            DagSourceFanKey(source: edge.from, targetLayer: depths[edge.to])
        }

        return grouped.reduce(into: [:]) { result, entry in
            let sortedEdges = entry.value.sorted { lhs, rhs in
                compareStepOrder(lhs: lhs.to, rhs: rhs.to, steps: steps)
            }
            result[entry.key] = DagSourceFan(
                source: entry.key.source,
                targetLayer: entry.key.targetLayer,
                edges: sortedEdges
            )
        }
    }

    private static func layerCenterGaps(
        layers: [[Int]],
        sourceFans: [DagSourceFanKey: DagSourceFan],
        contentHeight: CGFloat,
        inset: CGFloat,
        minCenterGap: CGFloat,
        maxCenterGap: CGFloat
    ) -> [CGFloat] {
        let usableHeight = max(contentHeight - inset * 2, minCenterGap)
        var maxFanCountByLayer: [Int: Int] = [:]
        for fan in sourceFans.values {
            maxFanCountByLayer[fan.targetLayer] = max(maxFanCountByLayer[fan.targetLayer] ?? 0, fan.edges.count)
        }

        return layers.enumerated().map { layerIndex, nodes in
            let laneCount = max(nodes.count, maxFanCountByLayer[layerIndex] ?? 0, 1)
            let scaledGap = usableHeight / CGFloat(max(laneCount - 1, 1))
            return clamp(scaledGap, min: minCenterGap, max: maxCenterGap)
        }
    }

    private static func sourceDrivenLayerPositions(
        layers: [[Int]],
        steps: [SpecStep],
        depths: [Int],
        incomingEdges: [Int: [DagEdge]],
        sourceFans: [DagSourceFanKey: DagSourceFan],
        contentHeight: CGFloat,
        inset: CGFloat,
        layerGaps: [CGFloat]
    ) -> [CGFloat] {
        var positions = Array(repeating: contentHeight / 2, count: steps.count)
        let bounds = inset ... (contentHeight - inset)

        for (layerIndex, nodes) in layers.enumerated() where !nodes.isEmpty {
            let gap = layerGap(at: layerIndex, layerGaps: layerGaps, fallback: 0)
            let centered = centeredTargets(count: nodes.count, bounds: bounds, gap: gap)
            var desiredByNode = Dictionary(uniqueKeysWithValues: zip(nodes, centered))

            if layerIndex > 0 {
                for node in nodes {
                    guard let incoming = incomingEdges[node], !incoming.isEmpty else { continue }
                    let targets = incoming.map { edge in
                        fanDerivedTargetY(
                            for: edge,
                            targetLayer: layerIndex,
                            positions: positions,
                            sourceFans: sourceFans,
                            gap: gap
                        )
                    }
                    desiredByNode[node] = average(of: targets)
                }
            }

            let targets = nodes.map { desiredByNode[$0] ?? (contentHeight / 2) }
            let adjusted = enforceOrderedLayer(
                targets: targets,
                minCenterGap: gap,
                bounds: bounds
            )
            for (node, y) in zip(nodes, adjusted) {
                positions[node] = y
            }
        }

        return positions
    }

    private static func fanDerivedTargetY(
        for edge: DagEdge,
        targetLayer: Int,
        positions: [CGFloat],
        sourceFans: [DagSourceFanKey: DagSourceFan],
        gap: CGFloat
    ) -> CGFloat {
        let fanKey = DagSourceFanKey(source: edge.from, targetLayer: targetLayer)
        let fanEdges = sourceFans[fanKey]?.edges ?? [edge]
        let fanIndex = fanEdges.firstIndex(where: { $0.from == edge.from && $0.to == edge.to }) ?? 0
        let centeredIndex = CGFloat(fanIndex) - CGFloat(fanEdges.count - 1) / 2
        return positions[edge.from] + centeredIndex * gap
    }

    private static func compareStepOrder(
        lhs: Int,
        rhs: Int,
        steps: [SpecStep]
    ) -> Bool {
        if steps[lhs].number == steps[rhs].number {
            return lhs < rhs
        }
        return steps[lhs].number < steps[rhs].number
    }

    private static func compareSourceOrder(
        lhs: Int,
        rhs: Int,
        depths: [Int],
        steps: [SpecStep]
    ) -> Bool {
        if depths[lhs] != depths[rhs] {
            return depths[lhs] < depths[rhs]
        }
        return compareStepOrder(lhs: lhs, rhs: rhs, steps: steps)
    }

    private static func centeredTargets(
        count: Int,
        bounds: ClosedRange<CGFloat>,
        gap: CGFloat
    ) -> [CGFloat] {
        guard count > 0 else { return [] }
        let mid = (bounds.lowerBound + bounds.upperBound) / 2
        guard count > 1 else { return [mid] }
        let span = CGFloat(count - 1) * gap
        let start = mid - span / 2
        return (0 ..< count).map { start + CGFloat($0) * gap }
    }

    private static func layerGap(
        at layer: Int,
        layerGaps: [CGFloat],
        fallback: CGFloat
    ) -> CGFloat {
        guard layerGaps.indices.contains(layer) else { return fallback }
        return layerGaps[layer]
    }

    private static func enforceOrderedLayer(
        targets: [CGFloat],
        minCenterGap: CGFloat,
        bounds: ClosedRange<CGFloat>
    ) -> [CGFloat] {
        guard !targets.isEmpty else { return [] }
        var adjusted = targets
        adjusted[0] = max(bounds.lowerBound, adjusted[0])
        for index in 1 ..< adjusted.count {
            adjusted[index] = max(adjusted[index], adjusted[index - 1] + minCenterGap)
        }

        if let last = adjusted.last, last > bounds.upperBound {
            adjusted[adjusted.count - 1] = bounds.upperBound
            if adjusted.count > 1 {
                for index in stride(from: adjusted.count - 2, through: 0, by: -1) {
                    adjusted[index] = min(adjusted[index], adjusted[index + 1] - minCenterGap)
                }
            }
        }

        if adjusted[0] < bounds.lowerBound {
            let shift = bounds.lowerBound - adjusted[0]
            adjusted = adjusted.map { $0 + shift }
        }
        if let last = adjusted.last, last > bounds.upperBound {
            let shift = last - bounds.upperBound
            adjusted = adjusted.map { $0 - shift }
        }

        return adjusted
    }

    private static func buildEdgePorts(
        edges: [DagEdge],
        centers: [Int: CGPoint],
        nodeRadius: CGFloat,
        depths: [Int],
        steps: [SpecStep],
        sourceFans: [DagSourceFanKey: DagSourceFan],
        layerGaps: [CGFloat]
    ) -> [DagEdgePair: DagEdgePorts] {
        var fromOffsets: [DagEdgePair: CGFloat] = [:]
        var toOffsets: [DagEdgePair: CGFloat] = [:]

        for fan in sourceFans.values {
            let gap = layerGap(at: fan.targetLayer, layerGaps: layerGaps, fallback: nodeRadius * 2)
            let spacing = min(nodeRadius * 0.7, gap * 0.28)
            for (edge, offset) in zip(fan.edges, centeredOffsets(count: fan.edges.count, spacing: spacing)) {
                fromOffsets[DagEdgePair(from: edge.from, to: edge.to)] = offset
            }
        }

        let incoming = Dictionary(grouping: edges, by: \.to)
        for (target, nodeEdges) in incoming {
            let sortedEdges = nodeEdges.sorted {
                let lhsY = centers[$0.from]?.y ?? 0
                let rhsY = centers[$1.from]?.y ?? 0
                if lhsY == rhsY {
                    return compareSourceOrder(lhs: $0.from, rhs: $1.from, depths: depths, steps: steps)
                }
                return lhsY < rhsY
            }
            let gap = layerGap(at: depths[target], layerGaps: layerGaps, fallback: nodeRadius * 2)
            let spacing = min(nodeRadius * 0.7, gap * 0.28)
            for (edge, offset) in zip(sortedEdges, centeredOffsets(count: sortedEdges.count, spacing: spacing)) {
                toOffsets[DagEdgePair(from: edge.from, to: edge.to)] = offset
            }
        }

        var ports: [DagEdgePair: DagEdgePorts] = [:]
        for edge in edges {
            let pair = DagEdgePair(from: edge.from, to: edge.to)
            ports[pair] = DagEdgePorts(
                fromOffset: fromOffsets[pair] ?? 0,
                toOffset: toOffsets[pair] ?? 0
            )
        }
        return ports
    }

    private static func centeredOffsets(
        count: Int,
        spacing: CGFloat
    ) -> [CGFloat] {
        guard count > 1 else { return [0] }
        let midpoint = CGFloat(count - 1) / 2
        return (0 ..< count).map { (CGFloat($0) - midpoint) * spacing }
    }

    private static func average(of values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / CGFloat(values.count)
    }
}

private struct DagEdgeGeometry {
    let start: CGPoint
    let control1: CGPoint
    let control2: CGPoint
    let end: CGPoint

    init(
        fromCenter: CGPoint,
        toCenter: CGPoint,
        nodeRadius: CGFloat,
        fromOffset: CGFloat,
        toOffset: CGFloat
    ) {
        self.start = Self.boundaryPoint(
            center: fromCenter,
            radius: nodeRadius,
            side: .right,
            verticalOffset: fromOffset
        )
        self.end = Self.boundaryPoint(
            center: toCenter,
            radius: nodeRadius,
            side: .left,
            verticalOffset: toOffset
        )

        let horizontalDistance = max(end.x - start.x, nodeRadius * 2.4)
        let bend = min(max(horizontalDistance * 0.34, nodeRadius * 1.4), 86)
        let verticalBias = (end.y - start.y) * 0.14
        self.control1 = CGPoint(x: start.x + bend, y: start.y + verticalBias)
        self.control2 = CGPoint(x: end.x - bend, y: end.y - verticalBias)
    }

    var path: Path {
        var path = Path()
        path.move(to: start)
        path.addCurve(to: end, control1: control1, control2: control2)
        return path
    }

    var arrowAngle: CGFloat {
        let tangent = cubicTangent(t: 0.96)
        return atan2(tangent.height, tangent.width)
    }

    func point(at t: CGFloat) -> CGPoint {
        let t = clamp(t, min: 0, max: 1)
        let mt = 1 - t
        let x =
            mt * mt * mt * start.x +
            3 * mt * mt * t * control1.x +
            3 * mt * t * t * control2.x +
            t * t * t * end.x
        let y =
            mt * mt * mt * start.y +
            3 * mt * mt * t * control1.y +
            3 * mt * t * t * control2.y +
            t * t * t * end.y
        return CGPoint(x: x, y: y)
    }

    private func cubicTangent(t: CGFloat) -> CGSize {
        let mt = 1 - t
        let x =
            3 * mt * mt * (control1.x - start.x) +
            6 * mt * t * (control2.x - control1.x) +
            3 * t * t * (end.x - control2.x)
        let y =
            3 * mt * mt * (control1.y - start.y) +
            6 * mt * t * (control2.y - control1.y) +
            3 * t * t * (end.y - control2.y)
        return CGSize(width: x, height: y)
    }

    private enum DagPortSide {
        case left
        case right
    }

    private static func boundaryPoint(
        center: CGPoint,
        radius: CGFloat,
        side: DagPortSide,
        verticalOffset: CGFloat
    ) -> CGPoint {
        let yOffset = clamp(verticalOffset, min: -radius * 0.78, max: radius * 0.78)
        let xOffset = sqrt(max(radius * radius - yOffset * yOffset, 0))
        switch side {
        case .left:
            return CGPoint(x: center.x - xOffset, y: center.y + yOffset)
        case .right:
            return CGPoint(x: center.x + xOffset, y: center.y + yOffset)
        }
    }
}

private struct DagEdgeCanvas: View {
    let edges: [DagEdge]
    let layout: DagLayout
    let liveStatuses: [Int: String]
    let caseStatus: String
    let hoveredStepIndex: Int?

    var body: some View {
        Canvas { context, _ in
            for edge in edges {
                guard let geometry = layout.geometry(for: edge) else { continue }
                let edgeColor = strokeColor(for: edge)
                let lineWidth = strokeWidth(for: edge)
                context.stroke(
                    geometry.path,
                    with: .color(edgeColor),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                )
                drawArrowHead(
                    in: &context,
                    tip: geometry.end,
                    angle: geometry.arrowAngle,
                    color: edgeColor
                )
            }
        }
        .frame(width: layout.contentSize.width, height: layout.contentSize.height)
    }

    private func drawArrowHead(
        in context: inout GraphicsContext,
        tip: CGPoint,
        angle: CGFloat,
        color: Color
    ) {
        let size: CGFloat = 5
        let wing: CGFloat = .pi / 7
        var path = Path()
        path.move(to: tip)
        path.addLine(to: CGPoint(
            x: tip.x - cos(angle - wing) * size,
            y: tip.y - sin(angle - wing) * size
        ))
        path.addLine(to: CGPoint(
            x: tip.x - cos(angle + wing) * size,
            y: tip.y - sin(angle + wing) * size
        ))
        path.closeSubpath()
        context.fill(path, with: .color(color))
    }

    private func strokeColor(for edge: DagEdge) -> Color {
        let opacityMultiplier = glowOpacity(for: edge)
        let fromStatus = liveStatuses[edge.from]
        let toStatus = liveStatuses[edge.to]

        switch toStatus {
        case "COMPLETED":              return Color.green.opacity((edge.isSkip ? 0.3 : 0.5) * opacityMultiplier)
        case "FAILED":                 return Color.red.opacity((edge.isSkip ? 0.34 : 0.56) * opacityMultiplier)
        case "READY", "RUNNING", "IN_PROGRESS":
            return Color.blue.opacity((edge.isSkip ? 0.34 : 0.56) * opacityMultiplier)
        default: break
        }

        switch fromStatus {
        case "READY", "RUNNING", "IN_PROGRESS":
            return Color.blue.opacity((edge.isSkip ? 0.34 : 0.56) * opacityMultiplier)
        case "SUCCESS", "COMPLETED":
            return Color.green.opacity((edge.isSkip ? 0.3 : 0.5) * opacityMultiplier)
        case "ERROR", "FAILED":
            return Color.red.opacity((edge.isSkip ? 0.34 : 0.56) * opacityMultiplier)
        default: break
        }
        switch caseStatus {
        case "COMPLETE", "COMPLETED": return Color.green.opacity((edge.isSkip ? 0.24 : 0.38) * opacityMultiplier)
        case "FAILED":                return Color.red.opacity((edge.isSkip ? 0.28 : 0.42) * opacityMultiplier)
        default:         return Color.secondary.opacity((edge.isSkip ? 0.2 : 0.3) * opacityMultiplier)
        }
    }

    private func strokeWidth(for edge: DagEdge) -> CGFloat {
        let isIncident = hoveredStepIndex == edge.from || hoveredStepIndex == edge.to
        if hoveredStepIndex != nil {
            return isIncident ? 1.1 : 0.9
        }
        return 0.9
    }

    private func glowOpacity(for edge: DagEdge) -> CGFloat {
        let isIncident = hoveredStepIndex == edge.from || hoveredStepIndex == edge.to
        return hoveredStepIndex != nil && !isIncident ? 0.22 : 1
    }

}

private struct DagGraphNode: View {
    let step: SpecStep
    let stepIndex: Int
    let status: String?
    let caseStatus: String
    let nodeRadius: CGFloat
    let hoveredStepIndex: Int?
    var isReady: Bool = false
    let isSelected: Bool
    let onSelect: () -> Void
    let onHoverChanged: (Bool) -> Void

    private var nodeColor: Color {
        switch status {
        case "READY", "RUNNING", "IN_PROGRESS": return .blue
        case "SUCCESS", "COMPLETED":   return .green
        case "ERROR", "FAILED":        return .red
        default: break
        }
        if isReady { return .blue }
        switch caseStatus {
        case "COMPLETE", "COMPLETED": return .green
        case "FAILED":                return .red
        default:         return Color.primary.opacity(0.72)
        }
    }

    private var fillColor: Color {
        let opacity: Double
        switch status {
        case "READY":
            opacity = 0.22
        case "RUNNING", "IN_PROGRESS":
            opacity = 0.28
        case "SUCCESS", "COMPLETED":
            opacity = 0.24
        default:
            opacity = isReady ? 0.22 : 0.12
        }
        return nodeColor.opacity(opacity)
    }

    private var isHighlighted: Bool {
        hoveredStepIndex == stepIndex || status == "READY" || status == "RUNNING" || status == "IN_PROGRESS"
    }

    private var isDimmed: Bool {
        // Only dim steps that haven't run yet — completed and running steps stay fully visible
        guard status == nil else { return false }
        return hoveredStepIndex != nil && hoveredStepIndex != stepIndex
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(fillColor)
            Circle()
                .stroke(nodeColor.opacity(0.9), lineWidth: 0.9)
            if isSelected {
                Circle()
                    .stroke(Color.accentColor.opacity(0.85), lineWidth: 3)
                    .padding(-4)
            }
            Circle()
                .fill(nodeColor.opacity(0.18))
                .frame(width: 10, height: 10)
        }
        .frame(width: nodeRadius * 2, height: nodeRadius * 2)
        .shadow(color: nodeColor.opacity(0.16), radius: 10, y: 4)
        .scaleEffect(isHighlighted ? 1.08 : 1)
        .opacity(isDimmed ? 0.3 : 1)
        .contentShape(Circle())
        .onTapGesture(perform: onSelect)
        .onHover(perform: onHoverChanged)
        .accessibilityElement()
        .accessibilityLabel(Text("Step \(step.number): \(step.title)"))
        .accessibilityValue(Text(status ?? caseStatus))
    }
}

private struct DispatcherInputsBar: View {
    let rootInputs: [String]
    let variables: [String: VariableMeta]
    let slots: [String: ProcessSlot]
    @Binding var hoveredSelection: CaseInspectionSelection?
    @Binding var pinnedSelection: CaseInspectionSelection?

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 180), spacing: 10, alignment: .top)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DISPATCHER INPUTS")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(rootInputs, id: \.self) { name in
                    let meta = variables[name] ?? VariableMeta(description: "", type: "")
                    let selection = CaseInspectionSelection.rootInput(name: name)
                    DispatcherInputCard(
                        name: name,
                        meta: meta,
                        slot: slots[name],
                        isSelected: pinnedSelection == selection,
                        onHoverChanged: { hovering in hoveredSelection = hovering ? selection : nil },
                        onSelect: { pinnedSelection = selection }
                    )
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
    }
}

private struct DispatcherInputCard: View {
    let name: String
    let meta: VariableMeta
    let slot: ProcessSlot?
    let isSelected: Bool
    let onHoverChanged: (Bool) -> Void
    let onSelect: () -> Void

    private var isFilled: Bool { slot?.isFilled ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isFilled ? Color.green : Color.secondary.opacity(0.22))
                    .frame(width: 7, height: 7)
                Text(name)
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: isFilled ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.system(size: 10))
                    .foregroundStyle(isFilled ? .green : .secondary)
            }

            if !meta.type.isEmpty {
                Text(meta.type.uppercased())
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Text(meta.description.isEmpty ? "Provided by dispatcher at case start." : meta.description)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(10)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.65) : (isFilled ? Color.green.opacity(0.28) : Color.secondary.opacity(0.14)), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover(perform: onHoverChanged)
    }
}

private func clamp(_ value: CGFloat, min lowerBound: CGFloat, max upperBound: CGFloat) -> CGFloat {
    Swift.min(Swift.max(value, lowerBound), upperBound)
}

// MARK: - Step card

private struct StepCard: View {
    let step: SpecStep
    let stepIndex: Int
    let liveStatus: String?
    let isActive: Bool
    var isReady: Bool = false
    var slotLookup: [String: ProcessSlot] = [:]
    var compact: Bool = false
    var isSelected: Bool = false
    var onSelect: (() -> Void)? = nil
    var onSelectSlot: ((String) -> Void)? = nil
    var onHoverSelectionChanged: ((Bool) -> Void)? = nil
    @Binding var hoveredStepIndex: Int?

    private var stripColor: Color {
        switch liveStatus {
        case "RUNNING", "IN_PROGRESS": return .blue
        case "SUCCESS", "COMPLETED":   return .green
        case "ERROR", "FAILED":        return .red
        default:
            if isActive  { return .blue }
            if isReady   { return Color.accentColor }
            if compact && isHighlighted { return Color.accentColor.opacity(0.7) }
            return .clear
        }
    }

    private var isHighlighted: Bool {
        hoveredStepIndex == stepIndex
    }

    private var isDimmed: Bool {
        hoveredStepIndex != nil && hoveredStepIndex != stepIndex
    }

    private var bodyBackground: Color {
        guard !compact else { return .clear }
        if isHighlighted {
            return Color.accentColor.opacity(0.09)
        }
        return isActive ? Color.accentColor.opacity(0.04) : Color.clear
    }

    private var regularInputs: [IOItem] {
        step.inputItems
    }

    private var regularOutputs: [IOItem] {
        step.outputs
    }

    private var displayResources: [String] {
        var seen = Set<String>()
        return (step.resources + step.suggestedResources).filter { seen.insert($0).inserted }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(stripColor.opacity(compact && !isHighlighted && liveStatus == nil && !isActive ? 0 : (isHighlighted ? 1 : 0.9)))
                .frame(width: 3)

            Group {
                if compact {
                    compactContent
                } else {
                    regularContent
                }
            }
            .padding(.horizontal, compact ? 12 : 14)
            .padding(.vertical, compact ? 10 : 12)
            .background(bodyBackground)
        }
        .opacity(isDimmed ? 0.45 : 1)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke((!compact && isHighlighted) || isSelected ? Color.accentColor.opacity(isSelected ? 0.6 : 0.34) : .clear, lineWidth: isSelected ? 1.5 : 1)
                .padding(.leading, 3)
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect?() }
        .onHover { hovering in
            hoveredStepIndex = hovering ? stepIndex : nil
            onHoverSelectionChanged?(hovering)
        }
    }

    @ViewBuilder
    private var regularContent: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Step \(step.number)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    if let status = liveStatus {
                        StepStatusPill(status: status)
                    }
                }

                Text(step.title)
                    .font(.body.weight(.medium))
                    .foregroundColor(isActive ? .primary : Color.primary.opacity(0.8))

                if !step.instructions.isEmpty {
                    Text(step.instructions)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !regularInputs.isEmpty || !regularOutputs.isEmpty {
                    HStack(alignment: .top, spacing: 16) {
                        if !regularInputs.isEmpty {
                            IOSection(label: "Inputs", items: regularInputs, maxVisible: 2, compact: false, onSelectSlot: onSelectSlot)
                        }
                        if !regularOutputs.isEmpty {
                            IOSection(label: "Outputs", items: regularOutputs, maxVisible: 2, compact: false, onSelectSlot: onSelectSlot)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !step.skills.isEmpty || !displayResources.isEmpty || !step.tools.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    if !step.skills.isEmpty {
                        TagGroup(label: "Skills", items: step.skills, compact: false)
                    }
                    if !displayResources.isEmpty {
                        TagGroup(label: "Resources", items: displayResources, compact: false)
                    }
                    if !step.tools.isEmpty {
                        TagGroup(label: "Tools", items: step.tools, compact: false)
                    }
                }
                .frame(width: 130, alignment: .topLeading)
            }
        }
    }

    @ViewBuilder
    private var compactContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Step \(step.number)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                if let status = liveStatus {
                    StepStatusPill(status: status)
                } else if isReady {
                    StepStatusPill(status: "READY")
                }
            }

            Text(step.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor((isActive || isReady) ? .primary : Color.primary.opacity(0.82))

            if !step.instructions.isEmpty {
                Text(step.instructions)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !regularInputs.isEmpty || !regularOutputs.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    if !regularInputs.isEmpty {
                        IOSection(label: "Inputs", items: regularInputs, maxVisible: 2, compact: true, onSelectSlot: onSelectSlot)
                    }
                    if !regularOutputs.isEmpty {
                        IOSection(label: "Outputs", items: regularOutputs, maxVisible: 2, compact: true, onSelectSlot: onSelectSlot)
                    }
                }
            }

            if !step.skills.isEmpty {
                TagGroup(label: "Skills", items: step.skills, compact: true, maxVisible: 2)
            }
            if !displayResources.isEmpty {
                TagGroup(label: "Resources", items: displayResources, compact: true, maxVisible: 2)
            }
            if !step.tools.isEmpty {
                TagGroup(label: "Tools", items: step.tools, compact: true, maxVisible: 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - IO section

private struct IOSection: View {
    let label: String
    let items: [IOItem]
    var maxVisible: Int = 2
    var compact: Bool = false
    var onSelectSlot: ((String) -> Void)? = nil
    @State private var expanded = false
    private var ioType: String {
        switch label.lowercased() {
        case "inputs":    return "IN"
        case "outputs":   return "OUT"
        default:          return "RES"
        }
    }
    private var visibleItems: [IOItem] { expanded ? items : Array(items.prefix(maxVisible)) }
    private var overflowCount: Int { max(0, items.count - maxVisible) }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 4) {
            Text(label.uppercased())
                .font(.system(size: compact ? 8 : 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.6)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(visibleItems.enumerated()), id: \.offset) { _, item in
                    let missingDesc = ioType == "IN" && item.description.isEmpty
                    CompactTokenChip(
                        text: item.name,
                        foreground: missingDesc ? Color.orange : .secondary,
                        background: missingDesc ? Color.orange.opacity(0.08) : .secondary.opacity(0.08),
                        stroke: missingDesc ? Color.orange.opacity(0.55) : .secondary.opacity(0.18),
                        font: .system(.caption2, design: .monospaced),
                        maxWidth: compact ? 104 : nil,
                        truncationMode: .middle
                    )
                        .hudTooltip(item: item, ioType: ioType)
                        .contentShape(Rectangle())
                        .onTapGesture { onSelectSlot?(item.name) }
                }
                if !expanded && overflowCount > 0 {
                    Button("+\(overflowCount) more") { expanded = true }
                        .buttonStyle(.plain)
                        .modifier(
                            CompactTokenChipModifier(
                                foreground: .secondary,
                                background: .secondary.opacity(0.12),
                                stroke: .secondary.opacity(0.28),
                                font: .system(.caption2, design: .monospaced),
                                maxWidth: compact ? 104 : nil,
                                truncationMode: .tail
                            )
                        )
                }
            }
        }
        .frame(minWidth: compact ? 90 : nil, maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - HUD tooltip

private struct HUDTooltipModifier: ViewModifier {
    let name: String
    let ioType: String
    let description: String
    let type: String

    @State private var isShowing = false
    @State private var hoverTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering {
                    hoverTask?.cancel()
                    hoverTask = Task { @MainActor in
                        do {
                            try await Task.sleep(nanoseconds: 700_000_000)
                            isShowing = true
                        } catch {}
                    }
                } else {
                    hoverTask?.cancel()
                    isShowing = false
                }
            }
            .popover(isPresented: $isShowing, arrowEdge: .bottom) {
                HUDTooltipView(name: name, ioType: ioType,
                               description: description, type: type)
            }
    }
}

private extension View {
    func hudTooltip(item: IOItem, ioType: String) -> some View {
        modifier(HUDTooltipModifier(
            name: item.name, ioType: ioType,
            description: item.description, type: item.type
        ))
    }
}

private struct HUDTooltipView: View {
    let name: String
    let ioType: String
    let description: String
    let type: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header bar
            HStack(spacing: 6) {
                Text("◈")
                    .font(.system(size: 8, weight: .black))
                    .foregroundStyle(Color.cyan)
                Text(name.uppercased())
                    .font(.system(.caption, design: .monospaced).weight(.bold))
                    .foregroundStyle(Color.cyan)
                    .tracking(0.6)
                    .lineLimit(1)
                Spacer()
                Text(ioType)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.cyan.opacity(0.5))
                    .tracking(1.5)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 1)
                            .stroke(Color.cyan.opacity(0.28), lineWidth: 0.5)
                    )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.cyan.opacity(0.07))

            // Scan-line divider
            HStack(spacing: 0) {
                Rectangle().fill(Color.cyan.opacity(0.5)).frame(height: 0.5)
                Color.clear.frame(width: 6, height: 0.5)
                Rectangle().fill(Color.cyan.opacity(0.22)).frame(width: 4, height: 0.5)
                Color.clear.frame(width: 3, height: 0.5)
                Rectangle().fill(Color.cyan.opacity(0.5)).frame(width: 1, height: 0.5)
            }

            // All chips: description + type (same contract regardless of IN/OUT/RES)
            VStack(alignment: .leading, spacing: 10) {
                if description.isEmpty, ioType == "IN" {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.orange)
                        Text("Description missing — add to ## Variables table")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Color.orange.opacity(0.85))
                    }
                } else if description.isEmpty, ioType == "RES" {
                    Text("Named step resource")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color.cyan.opacity(0.72))
                } else {
                    Text(description)
                        .font(.system(.callout))
                        .foregroundStyle(Color(red: 0.72, green: 0.88, blue: 0.96))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !type.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("TYPE")
                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.cyan.opacity(0.38))
                            .tracking(1.0)
                        Text(type)
                            .font(.system(.caption, design: .monospaced).weight(.medium))
                            .foregroundStyle(Color.cyan.opacity(0.75))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
        }
        .frame(width: 260)
        .background(Color(red: 0.04, green: 0.06, blue: 0.10))
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .stroke(Color.cyan.opacity(0.28), lineWidth: 0.75)
        )
        .shadow(color: Color.cyan.opacity(0.14), radius: 14)
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .preferredColorScheme(.dark)
    }
}

// MARK: - Tag group

private struct TagGroup: View {
    let label: String
    let items: [String]
    var compact: Bool = false
    var maxVisible: Int = .max

    private var visibleItems: [String] {
        Array(items.prefix(maxVisible))
    }

    private var overflowCount: Int {
        max(0, items.count - maxVisible)
    }

    var body: some View {
        if compact {
            HStack(alignment: .center, spacing: 8) {
                Text(label.uppercased())
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .tracking(0.6)
                    .frame(width: 74, alignment: .leading)

                HStack(spacing: 4) {
                    ForEach(visibleItems, id: \.self) { item in
                        CompactTokenChip(
                            text: item,
                            foreground: .secondary,
                            background: .secondary.opacity(0.08),
                            stroke: .secondary.opacity(0.12),
                            font: .system(size: 10),
                            maxWidth: 118,
                            truncationMode: .tail
                        )
                    }
                    if overflowCount > 0 {
                        CompactTokenChip(
                            text: "+\(overflowCount) more",
                            foreground: .secondary,
                            background: .secondary.opacity(0.12),
                            stroke: .secondary.opacity(0.24),
                            font: .system(.caption2, design: .monospaced),
                            maxWidth: 76,
                            truncationMode: .tail
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .tracking(0.6)
                ForEach(items, id: \.self) { item in
                    Text(item)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
        }
    }
}

private struct CompactTokenChip: View {
    let text: String
    let foreground: Color
    let background: Color
    let stroke: Color
    let font: Font
    var maxWidth: CGFloat? = nil
    var truncationMode: Text.TruncationMode = .tail

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(foreground)
            .lineLimit(1)
            .truncationMode(truncationMode)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(background)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(stroke, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
}

private struct CompactTokenChipModifier: ViewModifier {
    let foreground: Color
    let background: Color
    let stroke: Color
    let font: Font
    var maxWidth: CGFloat? = nil
    var truncationMode: Text.TruncationMode = .tail

    func body(content: Content) -> some View {
        content
            .font(font)
            .foregroundStyle(foreground)
            .lineLimit(1)
            .truncationMode(truncationMode)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(background)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(stroke, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

// MARK: - Step status pill

private struct StepStatusPill: View {
    let status: String

    var body: some View {
        Text(status)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(fg.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var fg: Color {
        switch status {
        case "RUNNING", "IN_PROGRESS": return .blue
        case "SUCCESS", "COMPLETED":   return .green
        case "ERROR", "FAILED":        return .red
        case "READY":                  return Color.accentColor
        case "BLOCKED":                return .orange
        default:         return .secondary
        }
    }
}

private struct DispatchSummaryCard: View {
    let detail: CaseDetailResponse

    private var assignment: [String: JSONValue] {
        detail.caseItem.dispatchPacketJson?.objectValue?["assignment"]?.objectValue ?? [:]
    }

    private var caseLogs: [ProcessLog] {
        detail.logs
            .filter { $0.stepId == nil }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Dispatch")
                .font(.subheadline.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if let executor = assignment["executor"]?.stringValue, !executor.isEmpty {
                        ExecutionMetaChip(text: "owner \(executor)")
                    }
                    if let profile = assignment["dispatch_profile"]?.stringValue, !profile.isEmpty {
                        ExecutionMetaChip(text: "profile \(profile)")
                    }
                }

                if let assignmentId = assignment["assignment_id"]?.stringValue, !assignmentId.isEmpty {
                    ExecutionMetaChip(text: "assignment \(assignmentId)")
                }
            }

            if let progress = detail.progress {
                HStack(spacing: 8) {
                    ExecutionMetaChip(text: "\(progress.completedStepCount)/\(progress.totalSteps) done")
                    if !progress.readySteps.isEmpty {
                        ExecutionMetaChip(text: "\(progress.readySteps.count) ready")
                    }
                    if !progress.runningSteps.isEmpty {
                        ExecutionMetaChip(text: "\(progress.runningSteps.count) active")
                    }
                    if !progress.failedSteps.isEmpty {
                        ExecutionMetaChip(text: "\(progress.failedSteps.count) failed")
                    }
                }
            }

            if !caseLogs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("CASE ACTIVITY")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .tracking(0.6)
                    ForEach(caseLogs.prefix(4)) { log in
                        ExecutionLogRow(log: log)
                    }
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
