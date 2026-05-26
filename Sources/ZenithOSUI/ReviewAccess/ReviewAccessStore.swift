import Foundation
import SwiftUI

@MainActor
final class ReviewAccessStore: ObservableObject {
    @AppStorage("reviewAccessConfigsJSON") private var configsJSON: String = "[]"
    @Published private(set) var configs: [ReviewAccessConfig] = []

    init() {
        load()
    }

    func load() {
        guard let data = configsJSON.data(using: .utf8),
              let decoded = try? JSONDecoder.reviewAccess.decode([ReviewAccessConfig].self, from: data) else {
            configs = []
            return
        }
        configs = decoded.sorted { $0.accessLabel.localizedCaseInsensitiveCompare($1.accessLabel) == .orderedAscending }
    }

    func upsert(_ config: ReviewAccessConfig) {
        var next = configs.filter { $0.id != config.id }
        next.append(config)
        configs = next.sorted { $0.accessLabel.localizedCaseInsensitiveCompare($1.accessLabel) == .orderedAscending }
        save()
    }

    func delete(_ config: ReviewAccessConfig) {
        configs.removeAll { $0.id == config.id }
        save()
    }

    func deleteAll() {
        configs = []
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder.reviewAccess.encode(configs),
              let text = String(data: data, encoding: .utf8) else { return }
        configsJSON = text
    }
}

private extension JSONEncoder {
    static var reviewAccess: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var reviewAccess: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
