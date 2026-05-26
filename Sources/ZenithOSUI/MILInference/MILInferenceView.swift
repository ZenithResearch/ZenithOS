import SwiftUI
import AppKit

struct MILInferenceView: View {
    @EnvironmentObject private var status: ZenithStatus

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                controls
                modelSwitcher
                endpointDetails
                logsPanel
                errorDetails
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("MIL")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: status.isRunning ? "bolt.circle.fill" : "bolt.slash.circle")
                    .font(.system(size: 28))
                    .foregroundStyle(status.isRunning ? .green : .secondary)
                Text("Multi-Model Inference Layer")
                    .font(.title2.weight(.semibold))
            }

            Text(status.statusText)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
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

            if status.isBusy {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var modelSwitcher: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Models")
                .font(.headline)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(status.modelChoices) { choice in
                    Button {
                        status.switchModel(choice)
                    } label: {
                        HStack {
                            Text(choice.label)
                            Spacer()
                            Image(systemName: "arrow.right.circle")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(status.isBusy)
                }
            }
        }
    }

    private var endpointDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Endpoint")
                .font(.headline)

            DetailRow(label: "Model", value: status.monitor?.model?.served_name ?? status.monitor?.model?.name ?? "Unknown")
            DetailRow(label: "Workers", value: workersText)
            DetailRow(label: "Cost posture", value: status.monitor?.cost_posture?.zero_idle_cost == true ? "Zero idle compute" : "Warm worker billing")

            if let baseURL = status.monitor?.openai_base_url, !baseURL.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text("base_url")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .leading)

                    Text(baseURL)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)

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
        .padding(.top, 4)
    }

    @ViewBuilder
    private var logsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Error Logs")
                    .font(.headline)

                Spacer()

                Button {
                    Task { await status.refreshLogs() }
                } label: {
                    Label("Refresh Logs", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.bordered)
                .disabled(status.isRefreshingLogs)

                Button {
                    status.openLogsConsole()
                } label: {
                    Label("Open RunPod Logs", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.bordered)
            }

            if status.isRefreshingLogs {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Refreshing log diagnostics...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = status.lastLogsError, !error.isEmpty {
                Text(error)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if let output = status.lastCommandOutput, !output.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Last zenith output")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(output)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            if let diagnostics = status.logDiagnostics {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text((diagnostics.summary?.status ?? "unknown").uppercased())
                            .font(.caption.weight(.bold))
                            .foregroundStyle(levelColor(diagnostics.summary?.status))
                        Text(diagnostics.summary?.message ?? "No diagnostic summary available.")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    if let endpointID = diagnostics.endpoint_id, !endpointID.isEmpty {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Endpoint")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 90, alignment: .leading)
                            Text(endpointID)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
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

                    if let health = diagnostics.health {
                        VStack(alignment: .leading, spacing: 4) {
                            DetailRow(label: "Completed", value: "\(health.jobs_completed ?? 0)")
                            DetailRow(label: "Jobs failed", value: "\(health.jobs_failed ?? 0)")
                            DetailRow(label: "In progress", value: "\(health.jobs_in_progress ?? 0)")
                            DetailRow(label: "Queued", value: "\(health.jobs_in_queue ?? 0)")
                            DetailRow(label: "Retried", value: "\(health.jobs_retried ?? 0)")
                            DetailRow(label: "Initializing", value: "\(health.workers_initializing ?? 0)")
                            DetailRow(label: "Ready", value: "\(health.workers_ready ?? 0)")
                            DetailRow(label: "Running", value: "\(health.workers_running ?? 0)")
                            DetailRow(label: "Idle", value: "\(health.workers_idle ?? 0)")
                            DetailRow(label: "Unhealthy", value: "\(health.workers_unhealthy ?? 0)")
                            DetailRow(label: "Throttled", value: "\(health.workers_throttled ?? 0)")
                        }
                    }

                    if let workers = diagnostics.workers, !workers.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Worker States")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            ForEach(Array(workers.enumerated()), id: \.offset) { _, worker in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(worker.id ?? "worker")
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                    Text(worker.desired_status ?? "unknown")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(levelColor(worker.desired_status))
                                    Text(worker.gpu ?? "no gpu")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if let cost = worker.cost_per_hr {
                                        Text(String(format: "$%.2f/hr", cost))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }

                    let lines = diagnostics.lines ?? []
                    if !lines.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                HStack(alignment: .top, spacing: 8) {
                                    Text((line.level ?? "info").uppercased())
                                        .font(.system(.caption2, design: .monospaced).weight(.bold))
                                        .foregroundStyle(levelColor(line.level))
                                        .frame(width: 58, alignment: .leading)
                                    Text(line.message ?? "")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .padding(10)
                        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            } else if !status.isRefreshingLogs {
                Text("Refresh logs to inspect endpoint errors. Raw worker stdout and stderr stay in the RunPod console.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var errorDetails: some View {
        if let error = status.lastError, !error.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Last Error")
                    .font(.headline)
                Text(error)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
    }

    private var workersText: String {
        let active = status.monitor?.cost_posture?.workers_min ?? 0
        let maximum = status.monitor?.cost_posture?.workers_max ?? 0
        return "\(active)/\(maximum)"
    }

    private func levelColor(_ value: String?) -> Color {
        switch value?.lowercased() {
        case "error", "failed", "unhealthy":
            return .red
        case "warning", "warn", "throttled", "exited", "unknown":
            return .orange
        default:
            return .secondary
        }
    }
}

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
        }
    }
}
