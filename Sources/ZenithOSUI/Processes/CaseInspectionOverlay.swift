import AppKit
import SwiftUI

struct CaseInspectionOverlayHost<Content: View>: View {
    @Binding var pinnedSelection: CaseInspectionSelection?
    let context: CaseInspectionContext
    let streamMode: CaseDetailStreamMode
    let onSelect: (CaseInspectionSelection) -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            CaseInspectionOverlay(
                selection: pinnedSelection ?? .overview,
                context: context,
                streamMode: streamMode,
                onSelect: onSelect,
                onClose: { self.pinnedSelection = .overview }
            )
            .frame(width: 440)
        }
        .animation(.easeInOut(duration: 0.16), value: pinnedSelection?.id)
    }
}

private struct CaseInspectionOverlay: View {
    let selection: CaseInspectionSelection
    let context: CaseInspectionContext
    let streamMode: CaseDetailStreamMode
    let onSelect: (CaseInspectionSelection) -> Void
    let onClose: () -> Void
    @State private var presentedFileReference: SlotFileReference?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(width: 430, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand(perform: onClose)
        .sheet(item: $presentedFileReference) { reference in
            SlotMarkdownPreviewModal(reference: reference)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("INSPECT")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.8)
                Text(selection.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(selection.id)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .padding(6)
            }
            .buttonStyle(.plain)
            .background(Color.secondary.opacity(0.12))
            .clipShape(Circle())
            .accessibilityLabel("Close inspection overlay")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .overview:
            overviewContent
        case .processDocument:
            processDocumentContent
        case let .requirement(_, title):
            CaseInspectionField(label: "Requirement", value: title)
            CaseInspectionNotice(text: "Requirement ledger detail is not decoded in the current payload.")
        case let .rootInput(name):
            rootInputContent(name: name)
        case let .step(index, stepID):
            stepContent(index: index, stepID: stepID)
        case let .slot(name):
            slotContent(name: name)
        case let .edge(from, to, slotNames):
            edgeContent(from: from, to: to, slotNames: slotNames)
        case let .caseLog(id):
            logContent(id: id)
        case let .execution(stepID):
            executionContent(stepID: stepID)
        case .raw:
            rawContent
        }
    }

    private var overviewContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            CaseInspectionField(label: "Case", value: context.processCase.displayTitle)
            CaseInspectionField(label: "Case ID", value: context.processCase.id, monospaced: true)
            CaseInspectionField(label: "Status", value: context.processCase.statusLabel)
            if let objective = context.processCase.objective, !objective.isEmpty {
                CaseInspectionField(label: "Objective", value: objective)
            }
            StreamModeMiniCard(mode: streamMode)
            slotList(title: "Produced outputs", slots: CaseInspectionModel.producedOutputSlots(context: context))
        }
    }

    private var processDocumentContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            CaseInspectionField(label: "Source", value: context.rawProcessSourceURL?.path ?? context.processCase.processPath ?? "Not available", monospaced: true)
            CaseInspectionField(label: "Markdown", value: context.rawProcessMarkdown?.isEmpty == false ? context.rawProcessMarkdown! : "Not available from current payload", monospaced: true)
        }
    }

    private func rootInputContent(name: String) -> some View {
        let slot = CaseInspectionModel.slotInspection(name: name, context: context)
        return VStack(alignment: .leading, spacing: 10) {
            CaseInspectionField(label: "Root input", value: name, monospaced: true)
            if let variable = slot.variable {
                CaseInspectionField(label: "Type", value: variable.type.isEmpty ? "Not specified" : variable.type)
                CaseInspectionField(label: "Description", value: variable.description.isEmpty ? "No variable description." : variable.description)
            }
            CaseInspectionField(label: "Provenance", value: slot.producerStep == nil ? "Dispatcher/root-provided input" : "Also produced by \(slot.producerStep!.title)")
            CaseInspectionField(label: "Value", value: slot.displayValue, monospaced: true)
            if let reference = slot.fileReference {
                SlotFileReferenceRow(reference: reference) { selectedReference in
                    if selectedReference.isMarkdownPreviewable {
                        presentedFileReference = selectedReference
                    }
                }
            }
        }
    }

    private func stepContent(index: Int, stepID: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let inspection = CaseInspectionModel.stepInspection(index: index, stepID: stepID, context: context) {
                CaseInspectionField(label: "Title", value: inspection.specStep.title)
                CaseInspectionField(label: "Instructions", value: inspection.specStep.instructions.isEmpty ? "No instructions decoded." : inspection.specStep.instructions)
                if let persisted = inspection.processStep {
                    CaseInspectionField(label: "Runtime status", value: persisted.runtimeStatus ?? persisted.status)
                    if let args = prettyInspectionJSON(persisted.argsJson) { CaseInspectionField(label: "Args", value: args, monospaced: true) }
                    if let result = prettyInspectionJSON(persisted.resultJson) { CaseInspectionField(label: "Result", value: result, monospaced: true) }
                    if let runtime = persisted.runtimeDisplayValue { CaseInspectionField(label: "Runtime state", value: runtime, monospaced: true) }
                } else {
                    CaseInspectionNotice(text: "No persisted runtime step is linked in the current payload.")
                }
                slotList(title: "Inputs", slots: inspection.inputSlots)
                slotList(title: "Outputs", slots: inspection.outputSlots)
                logList(inspection.logs)
                CaseInspectionNotice(text: "Runs, spans, artifacts, and execution events are not decoded in the current ZenithOS payload yet.")
            } else {
                CaseInspectionNotice(text: "Step is not present in the current process structure.")
            }
        }
    }

    private func slotContent(name: String) -> some View {
        let slot = CaseInspectionModel.slotInspection(name: name, context: context)
        return VStack(alignment: .leading, spacing: 10) {
            CaseInspectionField(label: "Slot", value: slot.name, monospaced: true)
            if let variable = slot.variable {
                CaseInspectionField(label: "Type", value: variable.type.isEmpty ? "Not specified" : variable.type)
                CaseInspectionField(label: "Description", value: variable.description.isEmpty ? "No variable description." : variable.description)
            }
            CaseInspectionField(label: "State", value: slot.isFilled ? "Filled" : "Pending")
            CaseInspectionField(label: "Value", value: slot.displayValue, monospaced: true)
            if let reference = slot.fileReference {
                SlotFileReferenceRow(reference: reference) { selectedReference in
                    if selectedReference.isMarkdownPreviewable {
                        presentedFileReference = selectedReference
                    }
                }
            }
            if let producer = slot.producerStep {
                linkedStepField(label: "Producer", step: producer)
            } else {
                CaseInspectionField(label: "Producer", value: context.rootInputs.contains(name) ? "Dispatcher/root input" : "No producer decoded")
            }
            if slot.consumerSteps.isEmpty {
                CaseInspectionField(label: "Consumers", value: "No consumers decoded")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    CaseInspectionCaption("CONSUMERS")
                    ForEach(slot.consumerSteps, id: \.id) { step in
                        linkedStepButton(step)
                    }
                }
            }
        }
    }

    private func edgeContent(from: Int, to: Int, slotNames: [String]) -> some View {
        let inspection = CaseInspectionModel.edgeInspection(from: from, to: to, context: context)
        return VStack(alignment: .leading, spacing: 10) {
            if let inspection {
                linkedStepField(label: "Source", step: inspection.fromStep)
                linkedStepField(label: "Target", step: inspection.toStep)
                if inspection.slots.isEmpty {
                    CaseInspectionNotice(text: "No carried slot is derivable for this edge from the current process structure.")
                } else {
                    slotList(title: "Carried slots", slots: inspection.slots)
                }
            } else {
                CaseInspectionField(label: "Source", value: "Step \(from + 1)")
                CaseInspectionField(label: "Target", value: "Step \(to + 1)")
                CaseInspectionField(label: "Slots", value: slotNames.isEmpty ? "None decoded" : slotNames.joined(separator: ", "))
            }
        }
    }

    private func logContent(id: String) -> some View {
        let log = context.detail?.logs.first(where: { $0.id == id })
        return VStack(alignment: .leading, spacing: 10) {
            if let log {
                CaseInspectionField(label: "Type", value: log.type)
                CaseInspectionField(label: "Message", value: log.message)
                CaseInspectionField(label: "Created", value: log.createdAt)
                if let metadata = log.metadataJson?.prettyPrintedString {
                    CaseInspectionField(label: "Metadata", value: metadata, monospaced: true)
                }
            } else {
                CaseInspectionNotice(text: "Log entry is not present in the current payload.")
            }
        }
    }

    private func executionContent(stepID: String?) -> some View {
        let running = (context.detail?.steps ?? []).filter(\.isRunning)
        return VStack(alignment: .leading, spacing: 10) {
            StreamModeMiniCard(mode: streamMode)
            if running.isEmpty {
                CaseInspectionNotice(text: "No active step is running. Rich run/span/artifact details are not decoded yet.")
            } else {
                ForEach(running, id: \.id) { step in
                    Button("Step \(step.idx + 1): \(step.name)") {
                        onSelect(.execution(stepID: step.id))
                    }
                    .buttonStyle(.link)
                    CaseInspectionField(label: "Status", value: step.runtimeStatus ?? step.status)
                }
            }
        }
    }

    private var rawContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            CaseInspectionField(label: "Case ID", value: context.processCase.id, monospaced: true)
            CaseInspectionField(label: "Process", value: context.processCase.processName ?? context.processCase.processPath ?? "Not available")
            CaseInspectionField(label: "Decoded slots", value: CaseInspectionModel.allSlotNames(context: context).joined(separator: "\n"), monospaced: true)
            CaseInspectionNotice(text: "Full raw JSON is not retained after decoding; this shows decoded fields available to ZenithOS.")
        }
    }

    private func slotList(title: String, slots: [CaseSlotInspection]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            CaseInspectionCaption(title.uppercased())
            if slots.isEmpty {
                Text("None")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(slots, id: \.name) { slot in
                    Button {
                        onSelect(.slot(name: slot.name))
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Circle()
                                .fill(slot.isFilled ? Color.green : Color.secondary.opacity(0.35))
                                .frame(width: 7, height: 7)
                                .padding(.top, 4)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(slot.name)
                                        .font(.system(.caption, design: .monospaced))
                                        .lineLimit(1)
                                    if let reference = slot.fileReference {
                                        Image(systemName: reference.previewKind == .markdown ? "doc.richtext" : "doc")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(reference.resolutionState == .missing ? .orange : .accentColor)
                                    }
                                }
                                if slot.isFilled {
                                    Text(slot.displayValue.replacingOccurrences(of: "\n", with: " "))
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .truncationMode(.middle)
                                }
                            }
                            Spacer(minLength: 0)
                            Text(slot.isFilled ? "filled" : "pending")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .help(slotHelpText(slot))
                }
            }
        }
    }

    private func logList(_ logs: [ProcessLog]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            CaseInspectionCaption("LOGS")
            if logs.isEmpty {
                Text("No linked logs in current payload.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(logs.prefix(8), id: \.id) { log in
                    Button(log.message) { onSelect(.caseLog(id: log.id)) }
                        .buttonStyle(.link)
                        .font(.caption)
                        .lineLimit(2)
                }
            }
        }
    }

    private func slotHelpText(_ slot: CaseSlotInspection) -> String {
        var lines = ["\(slot.name): \(slot.displayValue)"]
        if let producer = slot.producerStep {
            lines.append("Produced by Step \(producer.number): \(producer.title)")
        }
        if let reference = slot.fileReference {
            lines.append("File reference: \(reference.displayPath)")
            if reference.resolutionState == .missing {
                lines.append("Missing locally; click to inspect mount/fallback details.")
            } else if reference.isMarkdownPreviewable {
                lines.append("Click, then Preview to render this markdown output.")
            }
        } else {
            lines.append("Click to inspect the full slot value and provenance.")
        }
        return lines.joined(separator: "\n")
    }

    private func linkedStepField(label: String, step: SpecStep) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            CaseInspectionCaption(label.uppercased())
            linkedStepButton(step)
        }
    }

    private func linkedStepButton(_ step: SpecStep) -> some View {
        let index = max(0, step.number - 1)
        return Button("Step \(step.number): \(step.title)") {
            onSelect(.selectionForStep(arrayIndex: index, step: step))
        }
        .buttonStyle(.link)
        .font(.caption)
        .lineLimit(2)
    }
}

private struct CaseInspectionField: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            CaseInspectionCaption(label.uppercased())
            Text(value)
                .font(monospaced ? .system(.caption, design: .monospaced) : .caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct CaseInspectionCaption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .tracking(0.6)
    }
}

private struct SlotFileReferenceRow: View {
    let reference: SlotFileReference
    let onPreview: (SlotFileReference) -> Void
    @State private var materializationMessage: String?
    @State private var isMaterializing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 3) {
                    CaseInspectionCaption(title.uppercased())
                    Text(reference.displayPath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    if reference.resolutionState == .missing {
                        Text("File does not resolve locally or through configured Hub artifact mounts.")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    } else if reference.resolutionState == .hubArtifact {
                        Text("Available through Hub artifact: \(reference.sourceLabel ?? reference.artifactID ?? "registered artifact")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let materializationURL = reference.materializationURL {
                            Text("Will materialize into: \(materializationURL.path)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    } else if reference.resolutionState == .mountedFile, let sourceLabel = reference.sourceLabel {
                        Text("Resolved through configured Hub mount: \(sourceLabel)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                if reference.isMarkdownPreviewable {
                    Button(reference.materializationURL == nil ? "Preview" : "Materialize & Preview") { onPreview(reference) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                } else if reference.resolutionState == .hubArtifact, reference.materializationURL != nil {
                    Button(isMaterializing ? "Materializing…" : "Materialize") {
                        Task { await materializeGenericArtifact() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isMaterializing)
                }
                if let materializationMessage {
                    Text(materializationMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let url = reference.url {
                    Button("Open") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                if reference.isLocalFile, let url = reference.url {
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var title: String {
        switch reference.resolutionState {
        case .remoteURL:
            return "Remote URL"
        case .missing:
            return "Missing file reference"
        case .unsupported:
            return "Unsupported reference"
        case .hubArtifact:
            return reference.previewKind == .markdown ? "Hub Markdown artifact" : "Hub artifact"
        case .mountedFile:
            return reference.previewKind == .markdown ? "Mounted Markdown document" : "Mounted Hub file"
        case .localFile:
            return reference.previewKind == .markdown ? "Markdown document" : "File reference"
        }
    }

    private var iconName: String {
        switch reference.resolutionState {
        case .remoteURL:
            return "link"
        case .missing:
            return "questionmark.document"
        case .unsupported:
            return "exclamationmark.triangle"
        case .hubArtifact:
            return reference.previewKind == .markdown ? "doc.richtext" : "shippingbox"
        case .mountedFile:
            return reference.previewKind == .markdown ? "doc.richtext.fill" : "externaldrive.fill"
        case .localFile:
            return reference.previewKind == .markdown ? "doc.richtext" : "doc"
        }
    }

    private var iconColor: Color {
        switch reference.resolutionState {
        case .missing, .unsupported: return .orange
        case .remoteURL: return .blue
        case .hubArtifact: return .blue
        case .mountedFile: return .accentColor
        case .localFile: return reference.previewKind == .markdown ? .accentColor : .secondary
        }
    }

    @MainActor
    private func materializeGenericArtifact() async {
        isMaterializing = true
        materializationMessage = nil
        defer { isMaterializing = false }
        do {
            let result = try await HubArtifactMirror.materializeIfPossible(reference: reference)
            if let localURL = result.localURL {
                materializationMessage = "Materialized to \(localURL.path)"
                NSWorkspace.shared.activateFileViewerSelecting([localURL])
            } else {
                materializationMessage = "Fetched from Hub, but no local mirror path is configured."
            }
        } catch {
            materializationMessage = "Materialization failed: \(error.localizedDescription)"
        }
    }
}

private struct SlotMarkdownPreviewModal: View {
    let reference: SlotFileReference
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session: MarkdownReaderSession

    init(reference: SlotFileReference) {
        self.reference = reference
        let url = reference.url ?? reference.artifactContentURL ?? URL(fileURLWithPath: reference.displayPath)
        let document: MarkdownDocumentSource
        if reference.resolutionState == .hubArtifact {
            document = MarkdownDocumentSource(
                title: URL(fileURLWithPath: reference.displayPath).deletingPathExtension().lastPathComponent,
                markdown: "Loading Hub artifact…",
                sourceURL: reference.artifactContentURL,
                context: .process
            )
        } else {
            document = (try? MarkdownDocumentSource.fromFileURL(url, context: .process))
                ?? MarkdownDocumentSource(
                    title: url.deletingPathExtension().lastPathComponent,
                    markdown: "Could not read markdown document.",
                    sourceURL: url,
                    context: .process
                )
        }
        self._session = StateObject(
            wrappedValue: MarkdownReaderSession(
                initialDocument: document,
                linkResolver: MarkdownLinkNavigator.makeResolver(context: .process)
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.currentDocument.title)
                        .font(.title3.weight(.semibold))
                    Text((session.currentDocument.sourceURL ?? reference.url)?.path ?? reference.displayPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
                if let url = session.currentDocument.sourceURL ?? reference.url {
                    Button("Open") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.bordered)
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .buttonStyle(.bordered)
                }
                Button("Close") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(18)

            Divider()

            MarkdownReaderView(session: session)
                .frame(minWidth: 760, minHeight: 520)
        }
        .frame(minWidth: 760, minHeight: 600)
        .task(id: reference.id) { await loadHubArtifactIfNeeded() }
    }

    private func adminBaseURL() -> URL {
        guard var url = reference.artifactContentURL,
              let path = reference.artifactContentPath else {
            return ReviewAccessHubClient.defaultHubURL
        }
        for _ in path.split(separator: "/") {
            url.deleteLastPathComponent()
        }
        return url
    }

    private func loadHubArtifactIfNeeded() async {
        guard reference.resolutionState == .hubArtifact else { return }
        do {
            let result = try await HubArtifactMirror.materializeIfPossible(reference: reference)
            let markdown = String(data: result.data, encoding: .utf8) ?? "Could not decode Hub artifact as UTF-8 Markdown."
            let sourceURL = result.localURL ?? reference.artifactContentURL
            let title = (result.localURL ?? URL(fileURLWithPath: reference.displayPath)).deletingPathExtension().lastPathComponent
            session.setDocument(
                MarkdownDocumentSource(
                    title: title,
                    markdown: markdown,
                    sourceURL: sourceURL,
                    context: .process
                ),
                resetHistory: true
            )
        } catch {
            session.setDocument(
                MarkdownDocumentSource(
                    title: "Hub artifact unavailable",
                    markdown: "Could not load or materialize Hub artifact.\n\n`\(error.localizedDescription)`",
                    sourceURL: reference.artifactContentURL,
                    context: .process
                ),
                resetHistory: true
            )
        }
    }
}

private struct CaseInspectionNotice: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct StreamModeMiniCard: View {
    let mode: CaseDetailStreamMode

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(mode.tint).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(mode.label)
                    .font(.caption.weight(.semibold))
                Text(mode.detailText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .background(mode.tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private extension CaseDetailStreamMode {
    var label: String {
        switch self {
        case .off: return "Stream off"
        case .connecting: return "Connecting"
        case .live: return "Live"
        case .fallbackPolling: return "Polling"
        case .closed: return "Closed"
        }
    }

    var detailText: String {
        switch self {
        case .off: return "No detail stream active."
        case .connecting: return "Opening local case stream."
        case .live: return "Receiving case execution updates."
        case let .fallbackPolling(reason): return reason
        case let .closed(reason): return reason
        }
    }

    var tint: Color {
        switch self {
        case .off, .closed: return .secondary
        case .connecting: return .orange
        case .live: return .green
        case .fallbackPolling: return .blue
        }
    }
}

private func prettyInspectionJSON(_ raw: String?) -> String? {
    guard let raw, !raw.isEmpty else { return nil }
    guard let data = raw.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data),
          let pretty = try? JSONSerialization.data(withJSONObject: object, options: .prettyPrinted),
          let string = String(data: pretty, encoding: .utf8) else { return raw }
    return string
}
