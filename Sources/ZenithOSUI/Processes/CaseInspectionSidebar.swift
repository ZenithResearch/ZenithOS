import SwiftUI

struct CaseInspectionSidebar<Controls: View>: View {
    let title: String
    let subtitle: String?
    let context: CaseInspectionContext
    let streamMode: CaseDetailStreamMode
    @Binding var selection: CaseInspectionSelection?
    let onExpandDocument: (MarkdownDocumentSource) -> Void
    let processDocument: MarkdownDocumentSource?
    @ViewBuilder let controls: () -> Controls

    private var selected: CaseInspectionSelection { selection ?? .overview }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                controls()
                outlineSection
            }
            .padding(20)
        }
        .frame(width: 360)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("View Process Doc") {
                if let processDocument { onExpandDocument(processDocument) }
                selection = .processDocument
            }
            .buttonStyle(.link)
            .disabled(processDocument == nil)
        }
    }

    private var outlineSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("INSPECT")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.8)

            sidebarRow(.overview, icon: "rectangle.grid.1x2", label: "Overview", detail: context.processCase.statusLabel)
            sidebarRow(.processDocument, icon: "doc.richtext", label: "Process Doc", detail: context.rawProcessSourceURL?.lastPathComponent ?? context.processCase.processPath)

            if !context.rootInputs.isEmpty {
                sidebarGroup("DISPATCH / PACKET") {
                    ForEach(context.rootInputs, id: \.self) { name in
                        sidebarRow(.rootInput(name: name), icon: "tray.and.arrow.down", label: name, detail: slotState(name), monospaced: true)
                    }
                }
            }

            sidebarGroup("STEPS") {
                ForEach(Array(context.steps.enumerated()), id: \.element.id) { index, step in
                    sidebarRow(
                        .selectionForStep(arrayIndex: index, step: step),
                        icon: "circle.dotted",
                        label: "Step \(step.number): \(step.title)",
                        detail: processStepStatus(index: index, step: step)
                    )
                }
            }

            let slotNames = CaseInspectionModel.allSlotNames(context: context)
            if !slotNames.isEmpty {
                sidebarGroup("SLOTS") {
                    let filled = slotNames.filter { slotLookup[$0]?.isFilled == true }
                    let pending = slotNames.filter { slotLookup[$0]?.isFilled != true }
                    if !filled.isEmpty {
                        sidebarSubcaption("Filled")
                        ForEach(filled, id: \.self) { name in
                            sidebarRow(.slot(name: name), icon: "checkmark.circle.fill", label: name, detail: "filled", monospaced: true)
                        }
                    }
                    if !pending.isEmpty {
                        sidebarSubcaption("Pending")
                        ForEach(pending, id: \.self) { name in
                            sidebarRow(.slot(name: name), icon: "circle", label: name, detail: "pending", monospaced: true)
                        }
                    }
                }
            }

            if !(context.detail?.logs ?? []).isEmpty {
                sidebarGroup("LOGS") {
                    ForEach((context.detail?.logs ?? []).prefix(12), id: \.id) { log in
                        sidebarRow(.caseLog(id: log.id), icon: "list.bullet.rectangle", label: log.message, detail: log.type)
                    }
                }
            }

            sidebarGroup("EXECUTION") {
                sidebarRow(.execution(stepID: nil), icon: "waveform.path.ecg", label: streamMode.sidebarLabel, detail: streamMode.sidebarDetail)
            }

            sidebarRow(.raw, icon: "curlybraces", label: "Raw decoded fields", detail: "current payload")
        }
    }

    private var slotLookup: [String: ProcessSlot] {
        Dictionary(uniqueKeysWithValues: (context.detail?.slots ?? []).map { ($0.name, $0) })
    }

    private func slotState(_ name: String) -> String {
        slotLookup[name]?.isFilled == true ? "filled" : "pending"
    }

    private func processStepStatus(index: Int, step: SpecStep) -> String? {
        if let persisted = context.detail?.steps.first(where: { $0.idx == index || $0.stepId == String(step.id) }) {
            return persisted.runtimeStatus ?? persisted.status
        }
        return nil
    }

    private func sidebarGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.7)
                .padding(.top, 4)
            content()
        }
    }

    private func sidebarSubcaption(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.quaternary)
            .tracking(0.6)
            .padding(.top, 2)
    }

    private func sidebarRow(_ rowSelection: CaseInspectionSelection, icon: String, label: String, detail: String? = nil, monospaced: Bool = false) -> some View {
        Button {
            selection = rowSelection
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected == rowSelection ? Color.accentColor : Color.secondary)
                    .frame(width: 16)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(monospaced ? .system(.caption, design: .monospaced) : .caption)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(selected == rowSelection ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(selected == rowSelection ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private extension CaseDetailStreamMode {
    var sidebarLabel: String {
        switch self {
        case .off: return "Stream off"
        case .connecting: return "Connecting"
        case .live: return "Live stream"
        case .fallbackPolling: return "Polling fallback"
        case .closed: return "Stream closed"
        }
    }

    var sidebarDetail: String {
        switch self {
        case .off: return "no detail stream"
        case .connecting: return "opening local stream"
        case .live: return "receiving updates"
        case let .fallbackPolling(reason): return reason
        case let .closed(reason): return reason
        }
    }
}
