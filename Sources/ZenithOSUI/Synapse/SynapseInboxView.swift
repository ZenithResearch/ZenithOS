import SwiftUI

// MARK: - SynapseInboxView
//
// Sophia's client inbox. Sophia is the hub agent — a separate Matrix account
// whose credentials come from the hub .env (SOPHIA_MATRIX_USER / SOPHIA_MATRIX_PASSWORD).
// Her sessions are stored under the "sophia_" keychain prefix, independent of
// the hub owner's Matrix session.

struct SynapseInboxView: View {
    @EnvironmentObject private var hub: HubStore
    @State private var selectedRoom: MatrixRoom? = nil
    @State private var previews: [String: RoomPreview] = [:]
    @State private var isLoading = false

    var body: some View {
        NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260)
                    .navigationTitle("Sophia")
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button { Task { await reload() } } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .help("Refresh inbox")
                        }
                    }
            } detail: {
                if let room = selectedRoom {
                    RoomView(room: room, client: hub.sophia)
                        .id(room.id)
                } else {
                    emptyState
                }
            }
            .task { await reload() }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            agentHeader
            Divider()
            if isLoading && hub.sophiaRooms.isEmpty {
                ProgressView("Connecting…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = hub.sophiaError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") { Task { await reload() } }
                        .controlSize(.small)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if hub.sophiaRooms.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("No conversations")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(hub.sophiaRooms, selection: $selectedRoom) { room in
                    InboxRow(room: room, preview: previews[room.id])
                        .tag(room)
                }
                .listStyle(.sidebar)
            }
        }
    }

    private var agentHeader: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 36, height: 36)
                Text("S")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Sophia")
                    .font(.headline)
                if let userId = hub.sophia.userId {
                    Text(userId)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Circle()
                .fill(hub.matrixReachable ? Color.green : Color.red)
                .frame(width: 8, height: 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No conversation selected")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data

    private func reload() async {
        isLoading = true
        await hub.connectSophia()
        await loadPreviews()
        isLoading = false
    }

    private func loadPreviews() async {
        await withTaskGroup(of: (String, RoomPreview)?.self) { group in
            for room in hub.sophiaRooms {
                group.addTask {
                    guard let msg = try? await hub.sophia.messages(roomId: room.id, limit: 1).last
                    else { return nil }
                    return (room.id, RoomPreview(sender: msg.sender, body: msg.body, timestamp: msg.timestamp))
                }
            }
            for await result in group {
                if let (id, preview) = result {
                    previews[id] = preview
                }
            }
        }
    }
}

// MARK: - RoomPreview

private struct RoomPreview {
    let sender: String
    let body: String
    let timestamp: Date
}

// MARK: - InboxRow

private struct InboxRow: View {
    let room: MatrixRoom
    let preview: RoomPreview?

    private var shortSender: String {
        guard let p = preview else { return "" }
        let s = p.sender.hasPrefix("@") ? String(p.sender.dropFirst()) : p.sender
        return s.components(separatedBy: ":").first ?? s
    }

    private var timeString: String {
        guard let p = preview else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(p.timestamp) {
            return p.timestamp.formatted(date: .omitted, time: .shortened)
        } else if cal.isDateInYesterday(p.timestamp) {
            return "Yesterday"
        } else {
            return p.timestamp.formatted(date: .abbreviated, time: .omitted)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(room.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Spacer()
                if preview != nil {
                    Text(timeString)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            if let p = preview {
                HStack(spacing: 3) {
                    if !shortSender.isEmpty {
                        Text(shortSender + ":")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(p.body)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            } else {
                Text("No messages")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
    }
}
