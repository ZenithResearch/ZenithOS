import AppKit
import SwiftUI

struct PlaygroundView: View {
    @EnvironmentObject private var status: ZenithStatus
    @StateObject private var markdownSession = MarkdownReaderSession(
        initialDocument: MarkdownDocumentSource(
            title: "Document",
            markdown: "",
            context: .playground
        ),
        linkResolver: MarkdownLinkNavigator.makeResolver(context: .playground)
    )
    @State private var prompt = ""
    @State private var submittedPrompt: String?
    @State private var responseMarkdown = ""
    @State private var responseModel: String?
    @State private var responseBaseURL: String?
    @State private var errorMessage: String?
    @State private var isSending = false
    @State private var requestStartedAt: Date?
    @State private var requestFinishedAt: Date?
    @State private var requestElapsedSeconds: TimeInterval = 0
    @FocusState private var promptFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Group {
                    if hasOutput {
                        outputLayout
                    } else {
                        hudOnlyLayout
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: hasOutput ? .leading : .center)
            }

            Divider()

            chatBar
        }
        .navigationTitle("Playground")
        .task {
            promptFocused = true
            while !Task.isCancelled {
                await status.refresh()
                await status.refreshLogs()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
        .task(id: isSending) {
            guard isSending else { return }
            while !Task.isCancelled && isSending {
                updateElapsed()
                await status.refresh()
                await status.refreshLogs()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        .onChange(of: responseMarkdown) { newValue in
            let nextDocument = MarkdownDocumentSource(
                title: "Document",
                markdown: newValue,
                context: .playground
            )
            markdownSession.setDocument(nextDocument, resetHistory: true)
        }
    }

    private var hudOnlyLayout: some View {
        VStack(spacing: 18) {
            milHUD(compact: false)
        }
        .frame(maxWidth: .infinity, minHeight: 420, alignment: .center)
    }

    private var outputLayout: some View {
        PlaygroundOutputLayout(spacing: 16) {
            documentViewer
            milHUD(compact: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var documentViewer: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Document")
                        .font(.headline)
                    Text(responseSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Spacer()

                Button {
                    markdownSession.goBack()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
                .disabled(!markdownSession.canGoBack)

                Button {
                    markdownSession.goForward()
                } label: {
                    Label("Forward", systemImage: "chevron.right")
                }
                .buttonStyle(.bordered)
                .disabled(!markdownSession.canGoForward)

                Button {
                    copyResponse()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .disabled(responseMarkdown.isEmpty)
            }

            Divider()

            MarkdownReaderView(session: markdownSession)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func milHUD(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 16) {
            HStack(spacing: 10) {
                Image(systemName: status.isRunning ? "bolt.circle.fill" : "bolt.slash.circle")
                    .font(.system(size: compact ? 22 : 28))
                    .foregroundStyle(status.isRunning ? .green : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("MIL HUD")
                        .font(compact ? .headline : .title2.weight(.semibold))
                    Text(requestStateText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            Text(status.statusText)
                .font(compact ? .caption : .headline)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            hudControls(compact: compact)

            if status.isBusy || isSending {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(status.isBusy ? "Applying MIL command..." : "Waiting for model output...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let warning = primaryHUDWarning {
                Text(warning)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            endpointSection(compact: compact)
            workerSection(compact: compact)
            queueSection
            requestSection(compact: compact)
            costSection
            diagnosticsSection(compact: compact)

            if let errorMessage {
                PlaygroundErrorView(message: errorMessage)
            }
        }
        .padding(compact ? 14 : 22)
        .frame(maxWidth: compact ? .infinity : 680, alignment: .leading)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.18),
                                .cyan.opacity(0.07),
                                .pink.opacity(0.06),
                                .black.opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.primary.opacity(0.10), lineWidth: 1)
            }
        }
        .shadow(color: .black.opacity(0.10), radius: compact ? 12 : 22, x: 0, y: compact ? 6 : 12)
    }

    private func endpointSection(compact: Bool) -> some View {
        PlaygroundHUDSection(title: "Endpoint") {
            PlaygroundMetricRow(label: "Model", value: activeModelName)
            PlaygroundMetricRow(label: "Warm / max", value: "\(workersMin)/\(workersMax)")
            PlaygroundMetricRow(label: "Posture", value: zeroIdleText)

            if let endpointID = endpointID, !endpointID.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    PlaygroundMetricRow(label: "Endpoint", value: compact ? shortID(endpointID) : endpointID)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(endpointID, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy endpoint id")
                }
            }

            if !compact, let baseURL = status.monitor?.openai_base_url, !baseURL.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    PlaygroundMetricRow(label: "base_url", value: baseURL)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(baseURL, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy base_url")
                }
            }
        }
    }

    private func workerSection(compact: Bool) -> some View {
        PlaygroundHUDSection(title: "Workers") {
            PlaygroundMetricGrid(items: [
                ("Booting", "\(health?.workers_initializing ?? 0)"),
                ("Ready", "\(health?.workers_ready ?? 0)"),
                ("Running", "\(health?.workers_running ?? 0)"),
                ("Idle", "\(health?.workers_idle ?? 0)"),
                ("Unhealthy", "\(health?.workers_unhealthy ?? 0)"),
                ("Throttled", "\(health?.workers_throttled ?? 0)")
            ])
            Text(workerExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            let workers = status.logDiagnostics?.workers ?? []
            if !workers.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(workers.prefix(compact ? 3 : 5).enumerated()), id: \.offset) { _, worker in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(shortID(worker.id ?? "worker"))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Text(worker.desired_status ?? "unknown")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(workerStatusColor(worker.desired_status))
                            if !compact {
                                Text(workerGPUText(worker.gpu))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                Text("No worker rows reported yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var queueSection: some View {
        PlaygroundHUDSection(title: "Queue & Jobs") {
            PlaygroundMetricGrid(items: [
                ("Queue", "\(health?.jobs_in_queue ?? 0)"),
                ("Active", "\(health?.jobs_in_progress ?? 0)"),
                ("Done", "\(health?.jobs_completed ?? 0)"),
                ("Failed", "\(health?.jobs_failed ?? 0)"),
                ("Retried", "\(health?.jobs_retried ?? 0)")
            ])

            if let warning = queuedReadyWarning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
    }

    private func requestSection(compact: Bool) -> some View {
        PlaygroundHUDSection(title: "Current Request") {
            PlaygroundMetricRow(label: "State", value: requestStateText)
            PlaygroundMetricRow(label: "Elapsed", value: elapsedText)
            PlaygroundMetricRow(label: "Prompt", value: "\(activePromptCharacterCount) chars")
            PlaygroundMetricRow(label: "Response", value: "\(responseMarkdown.count) chars")

            if let warning = longRequestWarning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            if let submittedPrompt {
                Text(submittedPrompt)
                    .font(.system(compact ? .caption : .body, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(compact ? 5 : 4)
                    .textSelection(.enabled)
            } else {
                Text("Send a message to the active MIL model.")
                    .font(compact ? .caption : .body)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var costSection: some View {
        PlaygroundHUDSection(title: "Cost Posture") {
            PlaygroundMetricRow(label: "Mode", value: zeroIdleText)
            PlaygroundMetricRow(label: "Est. burn", value: estimatedHourlyBurnText)
            if workersMin > 0 {
                Text("Warm workers are configured and may bill while idle.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if workersMax == 0 {
                Text("workers_max is zero; requests cannot start workers.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func diagnosticsSection(compact: Bool) -> some View {
        PlaygroundHUDSection(title: "RunPod Logs") {
            diagnosticsButtons(compact: compact)

            if status.isRefreshingLogs {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Refreshing diagnostics...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let diagnostics = status.logDiagnostics {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text((diagnostics.summary?.status ?? "unknown").uppercased())
                            .font(.system(.caption2, design: .monospaced).weight(.bold))
                            .foregroundStyle(summaryColor(diagnostics.summary?.status))
                            .frame(width: compact ? 54 : 64, alignment: .leading)

                        Text(diagnostics.summary?.message ?? "No diagnostic summary available.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(compact ? 5 : 3)
                            .textSelection(.enabled)
                    }

                    PlaygroundMetricRow(label: "Source", value: diagnostics.source ?? "unknown")

                    if let endpointID = diagnostics.endpoint_id, !endpointID.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            PlaygroundMetricRow(label: "Endpoint", value: compact ? shortID(endpointID) : endpointID)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(endpointID, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help("Copy endpoint id")
                        }
                    }

                    if let consoleURL = diagnostics.console_url, !consoleURL.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            PlaygroundMetricRow(label: "Console", value: consoleURL)
                            Button {
                                status.openLogsConsole()
                            } label: {
                                Image(systemName: "arrow.up.forward.app")
                            }
                            .buttonStyle(.borderless)
                            .help("Open RunPod logs")
                        }
                    }

                    diagnosticLinesView(compact: compact, diagnostics: diagnostics)
                }
            } else if !status.isRefreshingLogs {
                Text("Refresh logs to inspect RunPod endpoint, worker, pod, and vLLM probe failures.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let logsError = status.lastLogsError, !logsError.isEmpty {
                Text(logsError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }

            if let lastError = status.lastError, !lastError.isEmpty {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }

            if let output = status.lastCommandOutput, !output.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Last zenith output")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(output)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(compact ? 6 : 10)
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private func diagnosticLinesView(compact: Bool, diagnostics: LogDiagnosticsPayload) -> some View {
        let lines = diagnostics.lines ?? []
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Diagnostic Lines")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                ForEach(Array(lines.prefix(compact ? 8 : 14).enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 8) {
                        Text((line.level ?? "info").uppercased())
                            .font(.system(.caption2, design: .monospaced).weight(.bold))
                            .foregroundStyle(summaryColor(line.level))
                            .frame(width: 58, alignment: .leading)
                        Text(line.message ?? "")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }

                if lines.count > (compact ? 8 : 14) {
                    Text("\(lines.count - (compact ? 8 : 14)) more line(s) available on the MIL page.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    @ViewBuilder
    private func diagnosticsButtons(compact: Bool) -> some View {
        if compact {
            diagnosticsButtonsBody
                .labelStyle(.iconOnly)
        } else {
            diagnosticsButtonsBody
                .labelStyle(.titleAndIcon)
        }
    }

    private var diagnosticsButtonsBody: some View {
        HStack(spacing: 8) {
            Button {
                Task {
                    await status.refresh()
                    await status.refreshLogs()
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(status.isRefreshingLogs)

            Button {
                status.openLogsConsole()
            } label: {
                Label("RunPod Logs", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func hudControls(compact: Bool) -> some View {
        if compact {
            hudControlsBody
                .labelStyle(.iconOnly)
        } else {
            hudControlsBody
                .labelStyle(.titleAndIcon)
        }
    }

    private var hudControlsBody: some View {
        HStack(spacing: 8) {
            Button {
                status.setPower(true)
            } label: {
                Label("Start", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(status.isBusy)

            Button {
                status.setPower(false)
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
            .disabled(status.isBusy)

            Button {
                Task { await status.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(status.isBusy)
        }
    }

    private var chatBar: some View {
        HStack(alignment: .bottom, spacing: 12) {
            ZStack(alignment: .topLeading) {
                if prompt.isEmpty {
                    Text("Ask the active MIL model...")
                        .foregroundStyle(.secondary.opacity(0.72))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }

                TextField("", text: $prompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($promptFocused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .onSubmit {
                        submitFromKeyboard()
                    }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.primary.opacity(0.10), lineWidth: 1)
            }

            Button {
                Task { await submitPrompt() }
            } label: {
                if isSending {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 18, height: 18)
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(sendDisabled)
            .help(sendHelpText)

            Button("Clear") {
                clear()
            }
            .buttonStyle(.bordered)
            .disabled(isSending || (prompt.isEmpty && responseMarkdown.isEmpty && errorMessage == nil))
        }
        .padding(16)
        .background(.bar)
    }

    private var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasOutput: Bool {
        !responseMarkdown.isEmpty
    }

    private var requestStateText: String {
        if isSending {
            return "Generating"
        }
        if hasOutput {
            return "Output ready"
        }
        if errorMessage != nil {
            return "Request failed"
        }
        return "Ready"
    }

    private var health: LogDiagnosticsPayload.Health? {
        status.logDiagnostics?.health
    }

    private var endpointID: String? {
        status.logDiagnostics?.endpoint_id
    }

    private var activeModelName: String {
        status.monitor?.model?.served_name
            ?? status.monitor?.model?.name
            ?? responseModel
            ?? "Unknown"
    }

    private var workersMin: Int {
        status.monitor?.cost_posture?.workers_min ?? 0
    }

    private var workersMax: Int {
        status.monitor?.cost_posture?.workers_max ?? 0
    }

    private var zeroIdleText: String {
        status.monitor?.cost_posture?.zero_idle_cost == true ? "Zero idle: no warm workers" : "Warm: keeps workers online"
    }

    private var workerExplanation: String {
        "Warm/max is the billing floor and scale ceiling. Worker counts below are live RunPod health counters; rows are recent worker records and can include exited history."
    }

    private var activePromptCharacterCount: Int {
        if let submittedPrompt {
            return submittedPrompt.count
        }
        return trimmedPrompt.count
    }

    private var elapsedText: String {
        if requestStartedAt == nil {
            return "0.0s"
        }
        return String(format: "%.1fs", requestElapsedSeconds)
    }

    private var primaryHUDWarning: String? {
        podWarmingWarning ?? longRequestWarning ?? queuedReadyWarning
    }

    private var podWarmingWarning: String? {
        guard isPodBackend, !podInferenceReady else {
            return nil
        }
        return "The RunPod pod is running, but vLLM is not ready yet. Wait for Ready=1 before sending."
    }

    private var longRequestWarning: String? {
        guard isSending, requestElapsedSeconds >= 300 else {
            return nil
        }
        return "This request has been waiting over 5 minutes. Check worker logs or retry on a fresh H100 worker."
    }

    private var queuedReadyWarning: String? {
        let queued = health?.jobs_in_queue ?? 0
        let ready = health?.workers_ready ?? 0
        let running = health?.workers_running ?? 0
        guard queued > 0, ready > 0, running == 0 else {
            return nil
        }
        return "Jobs are queued while workers are ready. The worker request path may be stuck."
    }

    private var estimatedHourlyBurnText: String {
        let initializing = health?.workers_initializing ?? 0
        let idle = health?.workers_idle ?? 0
        let running = health?.workers_running ?? 0
        let ready = health?.workers_ready ?? 0
        let activeWorkers = max(initializing + idle + running, ready)
        guard activeWorkers > 0 else {
            return "$0.00/hr"
        }
        let workerCost = status.logDiagnostics?.workers?.compactMap(\.cost_per_hr).first ?? 0
        guard workerCost > 0 else {
            return "Unknown"
        }
        return String(format: "$%.2f/hr", Double(activeWorkers) * workerCost)
    }

    private var isPodBackend: Bool {
        if status.logDiagnostics?.source == "runpod_pod" {
            return true
        }
        return status.monitor?.openai_base_url?.contains(".proxy.runpod.net") == true
    }

    private var podInferenceReady: Bool {
        !isPodBackend || (health?.workers_ready ?? 0) > 0
    }

    private var sendDisabled: Bool {
        isSending || trimmedPrompt.isEmpty || !podInferenceReady
    }

    private var sendHelpText: String {
        if !podInferenceReady {
            return "MIL pod is still warming. Wait for Ready=1."
        }
        return "Send to MIL"
    }

    private func shortID(_ value: String) -> String {
        guard value.count > 10 else { return value }
        return String(value.prefix(10))
    }

    private func workerStatusColor(_ value: String?) -> Color {
        switch value?.lowercased() {
        case "running", "ready":
            return .green
        case "initializing", "exited":
            return .orange
        case "failed", "unhealthy":
            return .red
        default:
            return .secondary
        }
    }

    private func workerGPUText(_ value: String?) -> String {
        guard let value, !value.isEmpty else {
            return "GPU unknown/pending"
        }
        return value
    }

    private func summaryColor(_ value: String?) -> Color {
        switch value?.lowercased() {
        case "error":
            return .red
        case "warning", "unknown":
            return .orange
        default:
            return .secondary
        }
    }

    private var responseSubtitle: String {
        if let responseModel, let responseBaseURL {
            return "\(responseModel) via \(responseBaseURL)"
        }
        if let responseModel {
            return responseModel
        }
        return "Send a message from the chat bar."
    }

    private func submitFromKeyboard() {
        guard !isSending, !trimmedPrompt.isEmpty else { return }
        Task { await submitPrompt() }
    }

    @MainActor
    private func submitPrompt() async {
        let message = trimmedPrompt
        guard !message.isEmpty, !isSending else { return }
        guard podInferenceReady else {
            errorMessage = "MIL pod is still warming. Wait until RunPod Logs shows Ready=1, then send again."
            await status.refresh()
            await status.refreshLogs()
            return
        }

        submittedPrompt = message
        responseMarkdown = ""
        responseModel = nil
        responseBaseURL = nil
        errorMessage = nil
        requestStartedAt = Date()
        requestFinishedAt = nil
        requestElapsedSeconds = 0
        isSending = true
        await status.refresh()
        await status.refreshLogs()

        do {
            let result = try await PlaygroundInferenceClient().complete(
                prompt: message,
                systemPrompt: "You are ZenithOS. Answer directly. Format the response as clean Markdown when structure helps.",
                maxTokens: 1600,
                temperature: 0.4
            )
            responseMarkdown = result.content
            responseModel = result.model
            responseBaseURL = result.baseURL
            prompt = ""
            promptFocused = true
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }

        requestFinishedAt = Date()
        updateElapsed(now: requestFinishedAt ?? Date())
        isSending = false
        await status.refresh()
        await status.refreshLogs()
    }

    private func clear() {
        prompt = ""
        submittedPrompt = nil
        responseMarkdown = ""
        responseModel = nil
        responseBaseURL = nil
        errorMessage = nil
        requestStartedAt = nil
        requestFinishedAt = nil
        requestElapsedSeconds = 0
        promptFocused = true
    }

    private func copyResponse() {
        guard !responseMarkdown.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(responseMarkdown, forType: .string)
    }

    private func updateElapsed(now: Date = Date()) {
        guard let requestStartedAt else {
            requestElapsedSeconds = 0
            return
        }
        let end = requestFinishedAt ?? now
        requestElapsedSeconds = max(0, end.timeIntervalSince(requestStartedAt))
    }
}

private struct PlaygroundHUDSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PlaygroundMetricRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }
}

private struct PlaygroundMetricGrid: View {
    let items: [(String, String)]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.0)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(item.1)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }
}

private struct PlaygroundOutputLayout: Layout {
    var spacing: CGFloat
    private let collapseWidth: CGFloat = 860

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count >= 2 else {
            return .zero
        }

        let width = proposal.width ?? 980
        if width < collapseWidth {
            let first = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
            let second = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
            return CGSize(width: width, height: first.height + spacing + second.height)
        }

        let available = max(0, width - spacing)
        let documentWidth = floor(available * 0.8)
        let hudWidth = available - documentWidth
        let documentSize = subviews[0].sizeThatFits(ProposedViewSize(width: documentWidth, height: nil))
        let hudSize = subviews[1].sizeThatFits(ProposedViewSize(width: hudWidth, height: nil))
        return CGSize(width: width, height: max(documentSize.height, hudSize.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count >= 2 else {
            return
        }

        if bounds.width < collapseWidth {
            let firstSize = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subviews[0].place(
                at: bounds.origin,
                proposal: ProposedViewSize(width: bounds.width, height: firstSize.height)
            )
            subviews[1].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + firstSize.height + spacing),
                proposal: ProposedViewSize(width: bounds.width, height: nil)
            )
            return
        }

        let available = max(0, bounds.width - spacing)
        let documentWidth = floor(available * 0.8)
        let hudWidth = available - documentWidth
        subviews[0].place(
            at: bounds.origin,
            proposal: ProposedViewSize(width: documentWidth, height: bounds.height)
        )
        subviews[1].place(
            at: CGPoint(x: bounds.minX + documentWidth + spacing, y: bounds.minY),
            proposal: ProposedViewSize(width: hudWidth, height: bounds.height)
        )
    }
}

private struct PlaygroundEmptyDocumentView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("No response yet")
                .font(.headline)
            Text("Send a message to render the model output here.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct PlaygroundErrorView: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text("Request failed")
                    .font(.headline)
            }

            Text(message)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
