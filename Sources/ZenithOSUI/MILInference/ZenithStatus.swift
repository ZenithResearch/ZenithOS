import AppKit
import Foundation
import SwiftUI

struct MonitorPayload: Decodable {
    struct Model: Decodable {
        let name: String?
        let served_name: String?
    }

    struct CostPosture: Decodable {
        let workers_min: Int?
        let workers_max: Int?
        let zero_idle_cost: Bool?
    }

    let model: Model?
    let cost_posture: CostPosture?
    let openai_base_url: String?
}

struct LogDiagnosticsPayload: Decodable {
    struct Summary: Decodable {
        let status: String?
        let message: String?
    }

    struct Health: Decodable {
        let jobs_completed: Int?
        let jobs_failed: Int?
        let jobs_in_progress: Int?
        let jobs_in_queue: Int?
        let jobs_retried: Int?
        let workers_initializing: Int?
        let workers_idle: Int?
        let workers_ready: Int?
        let workers_running: Int?
        let workers_unhealthy: Int?
        let workers_throttled: Int?
    }

    struct Worker: Decodable {
        let id: String?
        let desired_status: String?
        let gpu: String?
        let cost_per_hr: Double?
    }

    struct Line: Decodable {
        let level: String?
        let message: String?
    }

    let source: String?
    let endpoint_id: String?
    let endpoint_name: String?
    let console_url: String?
    let summary: Summary?
    let health: Health?
    let workers: [Worker]?
    let lines: [Line]?
}

struct ModelChoice: Identifiable {
    let id: String
    let label: String
    let envPrefix: String
}

@MainActor
final class ZenithStatus: ObservableObject {
    @Published var statusText = "ZenithOS | starting"
    @Published var isRunning = false
    @Published var lastError: String?
    @Published var monitor: MonitorPayload?
    @Published var isBusy = false
    @Published var lastCommandOutput: String?
    @Published var logDiagnostics: LogDiagnosticsPayload?
    @Published var isRefreshingLogs = false
    @Published var lastLogsError: String?
    @Published var logsConsoleURL: URL?

    private var didAutoRefreshLogsForMonitorFailure = false

    private let models = [
        ModelChoice(id: "qwen3_6_235b", label: "Qwen 3.6", envPrefix: "QWEN3_6_235B"),
        ModelChoice(id: "gemma4", label: "Gemma 4", envPrefix: "GEMMA4"),
        ModelChoice(id: "gemma4_e4b_obliterated", label: "Gemma 4 E4B Obliterated", envPrefix: "GEMMA4_E4B_OBLITERATED"),
        ModelChoice(id: "gpt_oss_120b", label: "GPT-OSS 120B", envPrefix: "GPT_OSS_120B"),
        ModelChoice(id: "glm5", label: "GLM-5", envPrefix: "GLM5"),
    ]

    var modelChoices: [ModelChoice] {
        models
    }

    init() {
        startPolling()
    }

    func startPolling() {
        Task {
            while true {
                await refresh()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    func refresh() async {
        do {
            let payload = try await fetchMonitor()
            monitor = payload
            let model = payload.model?.served_name ?? payload.model?.name ?? "No model"
            let active = payload.cost_posture?.workers_min ?? 0
            let maxWorkers = payload.cost_posture?.workers_max ?? 0
            let idleMode = payload.cost_posture?.zero_idle_cost == true ? "zero idle" : "warm"
            statusText = "\(model) | \(active)/\(maxWorkers) workers | \(idleMode)"
            isRunning = maxWorkers > 0
            lastError = nil
            didAutoRefreshLogsForMonitorFailure = false
        } catch {
            statusText = "ZenithOS | offline"
            isRunning = false
            monitor = nil
            lastError = error.localizedDescription
            if !didAutoRefreshLogsForMonitorFailure {
                didAutoRefreshLogsForMonitorFailure = true
                await refreshLogs()
            }
        }
    }

    func switchModel(_ choice: ModelChoice) {
        Task {
            do {
                isBusy = true
                statusText = "Switching to \(choice.label)..."
                lastError = nil
                defer { isBusy = false }
                let env = modelEnvironment(for: choice)
                guard !env.isEmpty else {
                    throw NSError(
                        domain: "ZenithBar",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Set ZENITH_MODEL_\(choice.envPrefix)_MODEL_NAME in the app environment."]
                    )
                }
                _ = try await runZenith("up --yes", extraEnvironment: env)
                await refresh()
            } catch {
                lastError = error.localizedDescription
                statusText = "ZenithOS | command failed"
                await refreshLogs()
            }
        }
    }

    func setPower(_ enabled: Bool) {
        Task {
            do {
                isBusy = true
                statusText = enabled ? "Starting ZenithOS..." : "Stopping ZenithOS..."
                lastError = nil
                defer { isBusy = false }
                _ = try await runZenith(enabled ? "up --yes" : "down --yes")
                await refresh()
            } catch {
                lastError = error.localizedDescription
                statusText = "ZenithOS | command failed"
                await refreshLogs()
            }
        }
    }

    func refreshLogs() async {
        isRefreshingLogs = true
        defer { isRefreshingLogs = false }

        do {
            let output = try await runZenith("logs --json --tail 200", captureOutput: true)
            guard let data = output.data(using: .utf8) else {
                throw NSError(
                    domain: "ZenithBar",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "logs output unavailable"]
                )
            }
            let payload = try JSONDecoder().decode(LogDiagnosticsPayload.self, from: data)
            logDiagnostics = payload
            lastLogsError = nil
            logsConsoleURL = payload.console_url.flatMap(URL.init(string:))
        } catch {
            lastLogsError = error.localizedDescription
        }
    }

    func openLogsConsole() {
        if let endpointID = logDiagnostics?.endpoint_id, !endpointID.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(endpointID, forType: .string)
        }

        let url = logsConsoleURL ?? URL(string: "https://console.runpod.io/serverless")!
        NSWorkspace.shared.open(url)
    }

    private func fetchMonitor() async throws -> MonitorPayload {
        let output = try await runZenith("monitor --json", captureOutput: true)
        guard let data = output.data(using: .utf8) else {
            throw NSError(domain: "ZenithBar", code: 2, userInfo: [NSLocalizedDescriptionKey: "monitor output unavailable"])
        }
        return try JSONDecoder().decode(MonitorPayload.self, from: data)
    }

    private func modelEnvironment(for choice: ModelChoice) -> [String: String] {
        let env = ProcessInfo.processInfo.environment
        var values: [String: String] = [:]
        let prefix = "ZENITH_MODEL_\(choice.envPrefix)_"

        if let model = env[prefix + "MODEL_NAME"], !model.isEmpty {
            values["MODEL_NAME"] = model
        } else if choice.id == "gemma4_e4b_obliterated" {
            values["MODEL_NAME"] = "OBLITERATUS/gemma-4-E4B-it-OBLITERATED"
        } else if choice.id == "gpt_oss_120b" {
            values["MODEL_NAME"] = "openai/gpt-oss-120b"
        }

        if let served = env[prefix + "SERVED_NAME"], !served.isEmpty {
            values["OPENAI_SERVED_MODEL_NAME_OVERRIDE"] = served
        } else if choice.id == "gemma4_e4b_obliterated" {
            values["OPENAI_SERVED_MODEL_NAME_OVERRIDE"] = "gemma-4-e4b-it-obliterated"
        } else if choice.id == "gpt_oss_120b" {
            values["OPENAI_SERVED_MODEL_NAME_OVERRIDE"] = "gpt-oss-120b"
        }

        if choice.id == "gemma4_e4b_obliterated" {
            values["DTYPE"] = "bfloat16"
            values["QUANTIZATION"] = "none"
            values["MAX_MODEL_LEN"] = "32768"
            values["TENSOR_PARALLEL_SIZE"] = "1"
        }

        for key in ["DTYPE", "QUANTIZATION", "MAX_MODEL_LEN", "TENSOR_PARALLEL_SIZE", "GPU_MEMORY_UTILIZATION"] {
            if let value = env[prefix + key], !value.isEmpty {
                values[key] = value
            }
        }

        return values
    }

    private func runZenith(
        _ arguments: String,
        extraEnvironment: [String: String] = [:],
        captureOutput: Bool = false
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            do {
                let paths = try zenithPaths()
                process.executableURL = paths.cli
                process.currentDirectoryURL = paths.repoRoot
                process.arguments = arguments.split(separator: " ").map(String.init)
                process.environment = processEnvironment(repoRoot: paths.repoRoot, extraEnvironment: extraEnvironment)
            } catch {
                continuation.resume(throwing: error)
                return
            }

            process.standardOutput = stdout
            process.standardError = stderr
            process.terminationHandler = { finished in
                let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let combined = [output, errorOutput].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n")

                Task { @MainActor in
                    self.lastCommandOutput = combined.isEmpty ? nil : combined
                }

                if finished.terminationStatus == 0 {
                    continuation.resume(returning: captureOutput ? output : combined)
                } else {
                    continuation.resume(
                        throwing: NSError(
                            domain: "ZenithBar",
                            code: Int(finished.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: combined.isEmpty ? "zenith command failed" : combined]
                        )
                    )
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func zenithPaths() throws -> (cli: URL, repoRoot: URL) {
        let env = ProcessInfo.processInfo.environment
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser

        let repoCandidates = [
            env["ZENITH_REPO_ROOT"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) },
            URL(fileURLWithPath: "repos/zenith-inference/multi-model-inference-layer", relativeTo: home).standardizedFileURL,
            URL(fileURLWithPath: "claude-hub/repos/workspace/zenith-inference/multi-model-inference-layer", relativeTo: home).standardizedFileURL,
            URL(fileURLWithPath: "zenith-inference/multi-model-inference-layer", relativeTo: home).standardizedFileURL,
        ].compactMap { $0 }

        for repoRoot in repoCandidates {
            let configuredCLI = env["ZENITH_CLI_PATH"] ?? ""
            let cli = configuredCLI.isEmpty
                ? repoRoot.appendingPathComponent(".venv/bin/zenith")
                : resolvePath(configuredCLI, relativeTo: repoRoot)
            if fileManager.isExecutableFile(atPath: cli.path) {
                return (cli.standardizedFileURL, repoRoot.standardizedFileURL)
            }
        }

        if let configuredCLI = env["ZENITH_CLI_PATH"], !configuredCLI.isEmpty {
            let cli = URL(fileURLWithPath: NSString(string: configuredCLI).expandingTildeInPath)
            if fileManager.isExecutableFile(atPath: cli.path) {
                let repoRoot = inferRepoRoot(fromCLI: cli) ?? URL(fileURLWithPath: fileManager.currentDirectoryPath)
                return (cli.standardizedFileURL, repoRoot.standardizedFileURL)
            }
        }

        throw NSError(
            domain: "ZenithBar",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Could not find the zenith CLI. Set ZENITH_REPO_ROOT to the multi-model-inference-layer path or ZENITH_CLI_PATH to .venv/bin/zenith."]
        )
    }

    private func processEnvironment(repoRoot: URL, extraEnvironment: [String: String]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["ZENITH_REPO_ROOT"] = repoRoot.path
        env["ZENITH_ENV_FILE"] = repoRoot.appendingPathComponent(".env").path
        env["PATH"] = env["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        return env.merging(extraEnvironment) { _, new in new }
    }

    private func resolvePath(_ path: String, relativeTo repoRoot: URL) -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }
        return URL(fileURLWithPath: expanded, relativeTo: repoRoot).standardizedFileURL
    }

    private func inferRepoRoot(fromCLI cli: URL) -> URL? {
        let components = cli.standardizedFileURL.pathComponents
        guard components.suffix(3) == [".venv", "bin", "zenith"] else {
            return nil
        }
        let rootComponents = components.dropLast(3)
        return URL(fileURLWithPath: NSString.path(withComponents: Array(rootComponents)))
    }

    private func zenithCLI() -> String {
        let env = ProcessInfo.processInfo.environment
        let configured = env["ZENITH_CLI_PATH"] ?? ""
        let fallback = "./.venv/bin/zenith"
        let path = configured.isEmpty ? fallback : configured
        return shellQuote(resolveLocalPath(path))
    }

    private func resolveLocalPath(_ path: String) -> String {
        if path.hasPrefix("/") {
            return path
        }
        let base = ProcessInfo.processInfo.environment["ZENITH_REPO_ROOT"]
            ?? FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: base)).standardizedFileURL.path
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
