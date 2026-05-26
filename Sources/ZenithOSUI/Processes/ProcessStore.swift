import Foundation

private let casesBase: String? = ProcessInfo.processInfo.environment["CASES_HTTP_URL"]

private let decoder: JSONDecoder = {
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    return d
}()

enum CaseDetailStreamMode: Equatable {
    case off
    case connecting
    case live
    case fallbackPolling(String)
    case closed(String)
}

@MainActor
final class CaseStore: ObservableObject {
    @Published private(set) var openCases:   [ProcessCase] = []
    @Published private(set) var recentCases: [ProcessCase] = []
    @Published private(set) var isLoading    = false
    @Published private(set) var errorMessage: String? = nil
    @Published private(set) var detail: CaseDetailResponse? = nil
    @Published private(set) var detailStreamMode: CaseDetailStreamMode = .off

    private weak var hub: HubStore?
    private var pollTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var monitoredDetailCaseID: String? = nil

    init(hub: HubStore? = nil) {
        self.hub = hub
        startPolling()
    }

    deinit {
        pollTask?.cancel()
        streamTask?.cancel()
    }

    private var usesLocalCasesService: Bool {
        guard let casesBase else { return false }
        return !casesBase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var artifactContentBaseURL: URL? {
        if let casesBase, !casesBase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(string: casesBase)
        }
        return hub?.hubNodeBaseURL
    }

    var usesAdminArtifactAccess: Bool { !usesLocalCasesService }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func refresh() async {
        isLoading = true
        errorMessage = nil
        let detailCaseID = monitoredDetailCaseID
        do {
            async let open      = fetchList(status: "OPEN",        limit: 50)
            async let ready     = fetchList(status: "READY",       limit: 50)
            async let inFlight  = fetchList(status: "IN_PROGRESS", limit: 50)
            async let blocked   = fetchList(status: "BLOCKED",     limit: 50)
            async let complete  = fetchList(status: "COMPLETED",   limit: 10)
            async let failed    = fetchList(status: "FAILED",      limit: 10)
            let (o, r, i, b, c, f) = try await (open, ready, inFlight, blocked, complete, failed)
            openCases   = dedupeAndSort(o + r + i + b)
            recentCases = dedupeAndSort(c + f)
            // Poll detail whenever the detail stream is not live; fallback polling is explicit UI state.
            if detailStreamMode != .live {
                if let detailCaseID {
                    if let d = try? await fetchDetail(for: detailCaseID) {
                        detail = d
                        evaluateDetailStream(for: detailCaseID, detail: d)
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func startDetailMonitoring(for caseId: String) async {
        if monitoredDetailCaseID != caseId {
            streamTask?.cancel()
            streamTask = nil
            detailStreamMode = .off
        }
        monitoredDetailCaseID = caseId
        // Load initial state immediately, then decide whether a live detail stream is warranted.
        await loadDetail(for: caseId, clearExisting: detail?.caseItem.id != caseId)
        evaluateDetailStream(for: caseId, detail: detail)
    }

    func stopDetailMonitoring(for caseId: String) {
        guard monitoredDetailCaseID == caseId else { return }
        monitoredDetailCaseID = nil
        streamTask?.cancel()
        streamTask = nil
        detailStreamMode = .closed("navigated away")
        if detail?.caseItem.id == caseId {
            detail = nil
        }
    }

    func loadDetail(for caseId: String, clearExisting: Bool = true) async {
        if clearExisting { detail = nil }
        do {
            let fresh = try await fetchDetail(for: caseId)
            detail = fresh
            evaluateDetailStream(for: caseId, detail: fresh)
        } catch {}
    }

    // MARK: - SSE stream
    private func hasActiveExecution(_ detail: CaseDetailResponse?) -> Bool {
        guard let detail else { return false }
        if detail.steps.contains(where: { $0.isRunning }) { return true }
        if detail.progress?.runningSteps.isEmpty == false { return true }
        return ["IN_PROGRESS", "RUNNING"].contains(detail.caseItem.status.uppercased())
    }

    private func isTerminal(_ detail: CaseDetailResponse?) -> Bool {
        guard let status = detail?.caseItem.status.uppercased() else { return false }
        return ["COMPLETE", "COMPLETED", "FAILED"].contains(status)
    }

    private func evaluateDetailStream(for caseId: String, detail: CaseDetailResponse?) {
        guard monitoredDetailCaseID == caseId else { return }
        guard hasActiveExecution(detail), !isTerminal(detail) else {
            streamTask?.cancel()
            streamTask = nil
            detailStreamMode = .closed(isTerminal(detail) ? "terminal case" : "no active execution")
            return
        }

        guard usesLocalCasesService else {
            streamTask?.cancel()
            streamTask = nil
            detailStreamMode = .fallbackPolling("Polling — admin stream not exposed.")
            return
        }

        if streamTask == nil || streamTask?.isCancelled == true {
            startStream(for: caseId)
        }
    }

    private func startStream(for caseId: String) {
        streamTask?.cancel()
        detailStreamMode = .connecting
        streamTask = Task { [weak self] in
            guard let self else { return }
            await self.runStream(for: caseId)
        }
    }

    private func runStream(for caseId: String) async {
        guard let casesBase, let url = URL(string: "\(casesBase)/cases/\(caseId)/stream") else {
            detailStreamMode = .fallbackPolling("local cases stream URL unavailable")
            return
        }
        var backoff: Double = 1.0

        while !Task.isCancelled && monitoredDetailCaseID == caseId {
            do {
                detailStreamMode = .connecting
                let (bytes, _) = try await URLSession.shared.bytes(from: url)
                detailStreamMode = .live
                backoff = 1.0  // reset on successful connection

                for try await line in bytes.lines {
                    guard !Task.isCancelled else { return }

                    // SSE lines starting with "data:" carry an event
                    guard line.hasPrefix("data:") else { continue }

                    // Any event means something changed — re-fetch the full detail
                    if monitoredDetailCaseID == caseId,
                       let fresh = try? await fetchDetail(for: caseId) {
                        detail = fresh

                        if !hasActiveExecution(fresh) || isTerminal(fresh) {
                            streamTask?.cancel()
                            streamTask = nil
                            detailStreamMode = .closed(isTerminal(fresh) ? "terminal case" : "no active execution")
                            return
                        }
                    }
                }
            } catch {
                // Connection dropped — back off and reconnect while active execution remains visible.
                guard !Task.isCancelled && monitoredDetailCaseID == caseId else { return }
                detailStreamMode = .fallbackPolling("stream error; polling until reconnect")
                if let fresh = try? await fetchDetail(for: caseId) {
                    detail = fresh
                    guard hasActiveExecution(fresh), !isTerminal(fresh) else {
                        streamTask?.cancel()
                        streamTask = nil
                        detailStreamMode = .closed(isTerminal(fresh) ? "terminal case" : "no active execution")
                        return
                    }
                }
                try? await Task.sleep(for: .seconds(backoff))
                backoff = min(backoff * 2, 30.0)
            }
        }
    }

    // MARK: - Fetch helpers
    private func fetchList(status: String, limit: Int) async throws -> [ProcessCase] {
        let data: Data
        if let casesBase, !casesBase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let url = URL(string: "\(casesBase)/cases?status=\(status)&limit=\(limit)") else {
                return []
            }
            let (localData, _) = try await URLSession.shared.data(from: url)
            data = localData
        } else {
            guard let hub else {
                throw ReviewAccessHubClientError.badURL
            }
            guard hub.reviewAccessAdminVerified else {
                throw ReviewAccessHubClientError.http(401, "Hub admin credential has not been verified. Open Hub Connection and verify the Review Access admin token before loading production case state.")
            }
            let client = ReviewAccessHubClient(baseURL: hub.hubNodeBaseURL)
            data = try await client.adminData(
                path: "v1/admin/cases",
                queryItems: [
                    URLQueryItem(name: "status", value: status),
                    URLQueryItem(name: "limit", value: "\(limit)"),
                ]
            )
        }
        return try decoder.decode(CasesListResponse.self, from: data).cases
    }

    private func fetchDetail(for caseId: String) async throws -> CaseDetailResponse {
        let data: Data
        if let casesBase, !casesBase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let url = URL(string: "\(casesBase)/cases/\(caseId)") else {
                throw URLError(.badURL)
            }
            let (localData, _) = try await URLSession.shared.data(from: url)
            data = localData
        } else {
            guard let hub else {
                throw ReviewAccessHubClientError.badURL
            }
            guard hub.reviewAccessAdminVerified else {
                throw ReviewAccessHubClientError.http(401, "Hub admin credential has not been verified. Open Hub Connection and verify the Review Access admin token before loading production case detail.")
            }
            let client = ReviewAccessHubClient(baseURL: hub.hubNodeBaseURL)
            data = try await client.adminData(path: "v1/admin/cases/\(caseId)")
        }
        return try decoder.decode(CaseDetailResponse.self, from: data)
    }

    private func dedupeAndSort(_ cases: [ProcessCase]) -> [ProcessCase] {
        let merged = Dictionary(uniqueKeysWithValues: cases.map { ($0.id, $0) })
        return merged.values.sorted { $0.createdAt > $1.createdAt }
    }
}
