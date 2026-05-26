import Foundation

private let queueBase: String? = ProcessInfo.processInfo.environment["QUEUE_HTTP_URL"]

private func statusOrder(_ s: String) -> Int {
    switch s {
    case "pending":    return 0
    case "processing": return 1
    case "done":       return 2
    case "dlq":        return 3
    default:           return 4
    }
}

@MainActor
final class QueueStore: ObservableObject {
    @Published private(set) var messages: [QueueMessage] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String? = nil

    private weak var hub: HubStore?

    init(hub: HubStore? = nil) {
        self.hub = hub
        load()
    }

    func load() {
        isLoading = true
        errorMessage = nil
        Task {
            var all: [QueueMessage] = []
            var firstError: String? = nil
            for status in ["pending", "processing", "done", "dlq"] {
                do {
                    let data = try await fetchMessagesData(status: status)
                    let resp = try JSONDecoder().decode(PeekResponse.self, from: data)
                    all.append(contentsOf: resp.messages)
                } catch {
                    if firstError == nil { firstError = error.localizedDescription }
                }
            }
            self.messages = all.sorted {
                if $0.status != $1.status { return statusOrder($0.status) < statusOrder($1.status) }
                return $0.created_at > $1.created_at
            }
            self.errorMessage = all.isEmpty ? firstError : nil
            self.isLoading = false
        }
    }

    private func fetchMessagesData(status: String) async throws -> Data {
        if let queueBase, !queueBase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let url = URL(string: "\(queueBase)/queues/workspace/peek?n=200&status=\(status)") else {
                throw URLError(.badURL)
            }
            let (data, _) = try await URLSession.shared.data(from: url)
            return data
        }

        guard let hub else {
            throw ReviewAccessHubClientError.badURL
        }
        guard hub.reviewAccessAdminVerified else {
            throw ReviewAccessHubClientError.http(401, "Hub admin credential has not been verified. Open Hub Connection and verify the Review Access admin token before loading production queue state.")
        }
        let client = ReviewAccessHubClient(baseURL: hub.hubNodeBaseURL)
        return try await client.adminData(
            path: "v1/admin/queues/workspace/peek",
            queryItems: [
                URLQueryItem(name: "n", value: "200"),
                URLQueryItem(name: "status", value: status),
            ]
        )
    }
}
