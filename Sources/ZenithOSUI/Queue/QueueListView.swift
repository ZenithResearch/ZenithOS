import SwiftUI

// MARK: - Queue list (root of queue navigation stack)

struct QueueListView: View {
    @StateObject private var store: QueueStore

    init(hub: HubStore) {
        _store = StateObject(wrappedValue: QueueStore(hub: hub))
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.isLoading && store.messages.isEmpty {
                    ProgressView("Loading queue…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = store.errorMessage, store.messages.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text("Could not load queue")
                            .font(.headline)
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Retry") { store.load() }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(store.messages) { msg in
                        NavigationLink(value: msg) {
                            MessageRowView(message: msg)
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .navigationTitle("Workspace Queue")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Text(store.messages.isEmpty ? "" : "\(store.messages.count) messages")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .automatic) {
                    Button(action: { store.load() }) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .help("Refresh queue")
                }
            }
            .navigationDestination(for: QueueMessage.self) { msg in
                MessageDetailView(message: msg)
            }
        }
    }
}

// MARK: - Message row

struct MessageRowView: View {
    let message: QueueMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Status + event type + priority + timestamp
            HStack(spacing: 6) {
                StatusBadge(status: message.status)
                Text(message.event_type)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                if message.priority != 0 {
                    Text("p\(message.priority)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                Spacer()
                Text(message.created_at.formattedTimestamp)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // Source + sender
            if !message.source_type.isEmpty || !message.sender.isEmpty {
                HStack(spacing: 4) {
                    if !message.source_type.isEmpty {
                        Text(message.source_type)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.quaternary)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    if !message.sender.isEmpty {
                        Text(message.sender)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            // Attachment count for review submissions
            if message.event_type == "review_submitted",
               case .array(let assets) = message.payload["assets"],
               !assets.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "paperclip")
                        .font(.caption2)
                    Text("\(assets.count) attachment\(assets.count == 1 ? "" : "s")")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }

            // Body
            if message.message_body.isEmpty {
                Text("(no body)")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .italic()
            } else {
                Text(message.message_body)
                    .font(.body)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Status badge

struct StatusBadge: View {
    let status: String

    var body: some View {
        Text(status)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var foreground: Color {
        switch status {
        case "pending":    return .blue
        case "processing": return .orange
        case "done":       return .green
        case "dlq":        return .red
        default:           return .secondary
        }
    }

    private var background: Color {
        switch status {
        case "pending":    return .blue.opacity(0.12)
        case "processing": return .orange.opacity(0.12)
        case "done":       return .green.opacity(0.12)
        case "dlq":        return .red.opacity(0.12)
        default:           return .secondary.opacity(0.12)
        }
    }
}
