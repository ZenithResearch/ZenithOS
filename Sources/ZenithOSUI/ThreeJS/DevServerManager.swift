import Foundation
import SwiftUI

// MARK: - Server state

enum DevServerState: Equatable {
    case idle
    case starting
    case running(pid: Int32)
    case failed(String)
}

// MARK: - Manager

@MainActor
final class DevServerManager: ObservableObject {

    @Published private(set) var states: [String: DevServerState] = [:]  // keyed by RepoNote.id
    @Published private(set) var log:    [String: [String]] = [:]         // stdout/stderr lines

    private var processes: [String: Process] = [:]

    // MARK: Public

    func state(for repo: RepoNote) -> DevServerState {
        states[repo.id] ?? .idle
    }

    func start(_ repo: RepoNote, onReady: @escaping (URL) -> Void) {
        guard processes[repo.id] == nil else { return }

        states[repo.id] = .starting
        log[repo.id]    = []

        let process = Process()
        process.executableURL   = URL(fileURLWithPath: "/bin/zsh")
        process.arguments       = ["-lc", repo.devCommand]
        process.currentDirectoryURL = repo.localURL

        // Pipe stdout + stderr to our log
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError  = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.log[repo.id, default: []].append(contentsOf:
                    text.components(separatedBy: "\n").filter { !$0.isEmpty })
            }
        }

        process.terminationHandler = { [weak self] p in
            Task { @MainActor [weak self] in
                self?.processes.removeValue(forKey: repo.id)
                if self?.states[repo.id] == .running(pid: p.processIdentifier) {
                    self?.states[repo.id] = .idle
                }
            }
        }

        do {
            try process.run()
        } catch {
            states[repo.id] = .failed(error.localizedDescription)
            return
        }

        processes[repo.id] = process
        states[repo.id]    = .running(pid: process.processIdentifier)

        // Poll until the port is accepting connections, then call onReady
        let port = repo.devPort
        let repoId = repo.id
        Task {
            let url = URL(string: "http://localhost:\(port)")!
            for _ in 0..<30 {           // up to 15 s
                try? await Task.sleep(nanoseconds: 500_000_000)
                if await portIsOpen(port) {
                    await MainActor.run { onReady(url) }
                    return
                }
                // Stop polling if process died
                if await MainActor.run(body: { self.processes[repoId] == nil }) { return }
            }
        }
    }

    func stop(_ repo: RepoNote) {
        guard let process = processes[repo.id] else { return }
        // Kill the process group so child processes (e.g. Vite) also die
        kill(-process.processIdentifier, SIGTERM)
        process.terminate()
        processes.removeValue(forKey: repo.id)
        states[repo.id] = .idle
    }

    func isRunning(_ repo: RepoNote) -> Bool {
        if case .running = states[repo.id] { return true }
        return false
    }

    // MARK: Private

    private func portIsOpen(_ port: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port   = in_port_t(port).bigEndian
                addr.sin_addr.s_addr = inet_addr("127.0.0.1")
                let sock = socket(AF_INET, SOCK_STREAM, 0)
                guard sock >= 0 else { continuation.resume(returning: false); return }
                defer { close(sock) }
                let result = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                continuation.resume(returning: result == 0)
            }
        }
    }
}
