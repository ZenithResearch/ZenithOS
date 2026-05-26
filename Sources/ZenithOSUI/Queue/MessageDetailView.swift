import SwiftUI

struct MessageDetailView: View {
    let message: QueueMessage

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // Header — ID + status
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(message.id)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if !message.message_body.isEmpty {
                            Text(message.message_body)
                                .font(.title3.weight(.semibold))
                                .textSelection(.enabled)
                        }
                    }
                    Spacer()
                    StatusBadge(status: message.status)
                }

                Divider()

                // Frank analysis — reads from message.metadata["frank_analysis"]
                FrankAnalysisSectionView(analysis: message.frankAnalysis)

                Divider()

                // Core fields
                SectionLabel("Message")
                FieldGrid {
                    FieldRow(label: "Queue",       value: message.queue_name)
                    FieldRow(label: "Event Type",  value: message.event_type)
                    FieldRow(label: "Source Type", value: message.source_type.nilIfEmpty ?? "—")
                    FieldRow(label: "Sender",      value: message.sender.nilIfEmpty ?? "—")
                    FieldRow(label: "Priority",    value: "\(message.priority)")
                    FieldRow(label: "Status",      value: message.status)
                    FieldRow(label: "Worker",      value: message.worker_id.nilIfEmpty ?? "—")
                }

                Divider()

                // Timestamps
                SectionLabel("Timestamps")
                FieldGrid {
                    FieldRow(label: "Created", value: message.created_at.formattedTimestamp)
                    FieldRow(label: "Claimed", value: message.claimed_at.nilIfEmpty.map { $0.formattedTimestamp } ?? "—")
                    FieldRow(label: "Done",    value: message.done_at.nilIfEmpty.map { $0.formattedTimestamp } ?? "—")
                }

                Divider()

                // Delivery
                SectionLabel("Delivery")
                FieldGrid {
                    FieldRow(label: "Retries",       value: "\(message.retry_count) / \(message.max_retries)")
                    FieldRow(label: "Claim Timeout", value: "\(message.claim_timeout_s)s")
                    if !message.error.isEmpty {
                        FieldRow(label: "Error", value: message.error)
                    }
                }

                // Attachments — shown for review_submitted messages
                if message.event_type == "review_submitted",
                   case .array(let assets) = message.payload["assets"] {
                    Divider()
                    ReviewAttachmentsSection(assets: assets, hubBase: message.hubBase)
                }

                // Payload
                if !message.payload.isEmpty {
                    Divider()
                    JSONSection(title: "Payload", value: message.payload)
                }

                // Metadata
                if !message.metadata.isEmpty {
                    Divider()
                    JSONSection(title: "Metadata", value: message.metadata)
                }
            }
            .padding(24)
        }
        .navigationTitle(message.id)
    }
}

// MARK: - Layout helpers

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.5)
    }
}

struct FieldGrid<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
            content
        }
    }
}

struct FieldRow: View {
    let label: String
    let value: String
    var body: some View {
        GridRow {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
                .frame(minWidth: 100, alignment: .trailing)
            Text(value)
                .font(.body)
                .textSelection(.enabled)
                .gridColumnAlignment(.leading)
        }
    }
}

struct JSONSection: View {
    let title: String
    let value: [String: JSONValue]
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: { expanded.toggle() }) {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                }
            }
            .buttonStyle(.plain)

            if expanded {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(value.prettyJSON)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(.quaternary.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

// MARK: - Review attachments

struct ReviewAsset: Identifiable {
    let id: String
    let type: String
    let mimeType: String
    let sizeBytes: Int
    let index: Int
}

func parseAssets(_ values: [JSONValue]) -> [ReviewAsset] {
    var counts: [String: Int] = [:]
    return values.compactMap { value in
        guard case .object(let obj) = value,
              case .string(let id)   = obj["asset_id"],
              case .string(let type) = obj["asset_type"],
              case .string(let mime) = obj["mime_type"]
        else { return nil }
        let size: Int = { if case .int(let n) = obj["size_bytes"] { return n }; return 0 }()
        counts[type, default: 0] += 1
        return ReviewAsset(id: id, type: type, mimeType: mime, sizeBytes: size, index: counts[type]!)
    }
}

struct ReviewAttachmentsSection: View {
    let assets: [JSONValue]
    let hubBase: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Attachments")
            VStack(alignment: .leading, spacing: 6) {
                ForEach(parseAssets(assets)) { asset in
                    AttachmentRow(asset: asset, hubBase: hubBase)
                }
            }
        }
    }
}

struct AttachmentRow: View {
    let asset: ReviewAsset
    let hubBase: String

    @State private var expanded = false
    @State private var rawText: String? = nil
    @State private var loadError = false
    @State private var isLoading = false

    private var url: URL? { URL(string: "\(hubBase)/v1/reviews/assets/\(asset.id)") }

    private var label: String {
        switch asset.type {
        case "events":     return "Events JSON"
        case "audio":      return "Audio"
        case "screenshot": return "Screenshot \(asset.index)"
        default:           return asset.type.capitalized
        }
    }

    private var icon: String {
        switch asset.type {
        case "events":     return "doc.text"
        case "audio":      return "waveform"
        case "screenshot": return "photo"
        default:           return "paperclip"
        }
    }

    private var sizeLabel: String {
        let kb = asset.sizeBytes / 1024
        return kb > 0 ? "\(kb) KB" : "<1 KB"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon).frame(width: 14)
                    Text(label)
                    Text("·").foregroundStyle(.tertiary)
                    Text(sizeLabel).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.quaternary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            if expanded {
                previewContent
                    .padding(.top, 6)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: expanded)
        .onChange(of: expanded) { newValue in
            if newValue && asset.type == "events" && rawText == nil && !loadError {
                fetchText()
            }
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        switch asset.type {
        case "screenshot":
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    case .failure:
                        Label("Failed to load image", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    default:
                        ProgressView().frame(maxWidth: .infinity, alignment: .center).padding(8)
                    }
                }
                .frame(maxHeight: 400)
                .frame(maxWidth: .infinity)
            }

        case "events":
            Group {
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity, alignment: .center).padding(8)
                } else if loadError {
                    Label("Failed to load", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                } else if let text = rawText {
                    ScrollView([.horizontal, .vertical]) {
                        Text(text)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 240)
                    .background(.quaternary.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }

        default:
            if let url {
                Button("Open in external app") { NSWorkspace.shared.open(url) }
                    .font(.caption).buttonStyle(.plain)
                    .foregroundColor(.accentColor).padding(.leading, 4)
            }
        }
    }

    private func fetchText() {
        guard let url else { return }
        isLoading = true
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let str: String
                if let obj = try? JSONSerialization.jsonObject(with: data),
                   let pretty = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted),
                   let prettyStr = String(data: pretty, encoding: .utf8) {
                    str = prettyStr
                } else {
                    str = String(data: data, encoding: .utf8) ?? "(binary data)"
                }
                await MainActor.run { rawText = str; isLoading = false }
            } catch {
                await MainActor.run { loadError = true; isLoading = false }
            }
        }
    }
}

// MARK: - Helpers

private extension QueueMessage {
    var hubBase: String { "http://localhost:8080" }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
