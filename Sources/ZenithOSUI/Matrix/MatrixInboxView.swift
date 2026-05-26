import SwiftUI

// MARK: - MatrixInboxView

struct MatrixInboxView: View {
    @EnvironmentObject private var hub: HubStore
    @State private var selectedRoom: MatrixRoom? = nil
    @State private var showingNewRoom = false
    @State private var hoveredContact: VaultContact? = nil
    @State private var isDMLoading = false
    @State private var inviteContact: VaultContact? = nil

    var body: some View {
        if !hub.matrixLoggedIn {
            notConnectedView
        } else {
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 200, ideal: 240)
                    .navigationTitle("Matrix")
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button { showingNewRoom = true } label: {
                                Image(systemName: "plus")
                            }
                            .help("New Room")
                        }
                    }
                    .sheet(isPresented: $showingNewRoom) {
                        NewRoomSheet(client: hub.matrix) {
                            Task { await hub.refreshRooms() }
                        }
                    }
                    .sheet(item: $inviteContact) { contact in
                        InviteSheet(contact: contact, homeserver: hub.matrix.baseURL)
                    }
            } detail: {
                if let room = selectedRoom {
                    RoomView(room: room, client: hub.matrix)
                        .id(room.id)
                } else {
                    placeholderView
                }
            }
            .task { await hub.refreshRooms() }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selectedRoom) {
            // ── Rooms ────────────────────────────────────
            if !hub.matrixRooms.isEmpty {
                Section("Rooms") {
                    ForEach(hub.matrixRooms) { room in
                        RoomRow(room: room).tag(room)
                    }
                }
            }

            // ── Contacts ─────────────────────────────────
            if !hub.contacts.isEmpty {
                Section {
                    ForEach(hub.contacts) { contact in
                        ContactRow(
                            contact: contact,
                            isHovered: hoveredContact?.id == contact.id,
                            isLoading: isDMLoading,
                            onSelect: { matrixId in openDM(matrixId) },
                            onInvite: { inviteContact = contact }
                        )
                        .onHover { over in
                            hoveredContact = over ? contact : nil
                        }
                    }
                } header: {
                    HStack {
                        Text("Inbox")
                        Spacer()
                        Text("\(hub.contacts.count)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: Not connected

    private var notConnectedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "network.slash")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Not connected to Matrix")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Sign in from Hub Settings to view your rooms.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Placeholder

    private var placeholderView: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Select a room")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Open DM

    private func openDM(_ matrixId: String) {
        guard !isDMLoading else { return }
        isDMLoading = true
        Task {
            do {
                let room = try await hub.matrix.findOrCreateDM(userId: matrixId)
                // Add to rooms list if not already present
                if !hub.matrixRooms.contains(room) {
                    hub.matrixRooms.append(room)
                }
                selectedRoom = room
            } catch {
                // ignore — surface via room view error handling
            }
            isDMLoading = false
        }
    }
}

// MARK: - Room row

private struct RoomRow: View {
    let room: MatrixRoom

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(room.displayName)
                .font(.body)
                .lineLimit(1)
            Text(room.id)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Contact row

private struct ContactRow: View {
    let contact: VaultContact
    let isHovered: Bool
    let isLoading: Bool
    let onSelect: (String) -> Void
    let onInvite: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: contact.hasMatrix ? "person.circle.fill" : "person.circle")
                    .font(.body)
                    .foregroundStyle(contact.hasMatrix ? Color.accentColor : .secondary)

                Text(contact.displayName)
                    .font(.body)
                    .lineLimit(1)

                Spacer()

                if contact.hasMatrix {
                    // Badge showing account count when > 1
                    if contact.matrixIds.count > 1 {
                        Text("\(contact.matrixIds.count)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color(NSColor.separatorColor).opacity(0.4))
                            .clipShape(Capsule())
                    }
                } else {
                    // Invite button — only visible on hover
                    if isHovered {
                        Button("Invite") { onInvite() }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .transition(.opacity)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard contact.hasMatrix else { return }
                onSelect(contact.matrixIds[0])
            }

            // Expanded account list on hover (Matrix contacts only)
            if isHovered && contact.matrixIds.count > 1 {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(contact.matrixIds, id: \.self) { matrixId in
                        Button {
                            onSelect(matrixId)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "at")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Text(matrixId)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .padding(.leading, 22)
                            .padding(.vertical, 3)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 2)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .opacity(isLoading && contact.hasMatrix ? 0.5 : 1)
    }
}

// MARK: - RoomView

struct RoomView: View {
    let room: MatrixRoom
    let client: MatrixClient

    @State private var messages: [MatrixMessage] = []
    @State private var draft: String = ""
    @State private var isLoading = true
    @State private var error: String? = nil
    @State private var syncToken: String? = nil
    @State private var syncTask: Task<Void, Never>? = nil

    var body: some View {
        VStack(spacing: 0) {
            // ── Message thread ────────────────────────────
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding()
                        } else if messages.isEmpty {
                            Text("No messages yet.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding()
                        } else {
                            ForEach(messages) { msg in
                                MessageBubble(message: msg, myUserId: client.userId ?? "")
                                    .id(msg.id)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onChange(of: messages) { msgs in
                    if let last = msgs.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            if let err = error {
                Text(err).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }

            Divider()

            // ── Compose bar ───────────────────────────────
            HStack(spacing: 8) {
                TextField("Message \(room.displayName)…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .padding(.vertical, 8)
                    .onSubmit { sendMessage() }

                Button(action: sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? Color.secondary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: [.command])
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .navigationTitle(room.displayName)
        .task { await loadAndSync() }
        .onDisappear { syncTask?.cancel() }
    }

    // MARK: Load + sync

    private func loadAndSync() async {
        isLoading = true
        do {
            messages = try await client.messages(roomId: room.id, limit: 60)
            // Grab a sync token without processing events, so sync loop starts fresh
            let initial = try await client.sync(since: nil, timeout: 0)
            syncToken = initial.nextBatch
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
        startSyncLoop()
    }

    private func startSyncLoop() {
        syncTask?.cancel()
        syncTask = Task {
            while !Task.isCancelled {
                do {
                    let result = try await client.sync(since: syncToken, timeout: 10_000)
                    syncToken = result.nextBatch
                    if let newMsgs = result.roomEvents[room.id], !newMsgs.isEmpty {
                        let knownIds = Set(messages.map(\.id))
                        let fresh = newMsgs.filter { !knownIds.contains($0.id) }
                        if !fresh.isEmpty {
                            await MainActor.run { messages.append(contentsOf: fresh) }
                        }
                    }
                } catch {
                    if Task.isCancelled { break }
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
        }
    }

    // MARK: Send

    private func sendMessage() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        Task {
            do {
                try await client.send(roomId: room.id, text: text)
                // Optimistic: append immediately, sync will deduplicate
                let optimistic = MatrixMessage(
                    id: "pending-\(UUID().uuidString)",
                    sender: client.userId ?? "",
                    body: text,
                    timestamp: Date()
                )
                await MainActor.run { messages.append(optimistic) }
            } catch {
                self.error = error.localizedDescription
                await MainActor.run { draft = text }
            }
        }
    }
}

// MARK: - Invite sheet

private struct InviteSheet: View {
    let contact: VaultContact
    let homeserver: String

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private var registrationURL: String {
        // Strip trailing slash, append /_matrix/static/#/register
        let base = homeserver.hasSuffix("/") ? String(homeserver.dropLast()) : homeserver
        return "\(base)/_matrix/static/#/register"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "person.badge.plus")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Invite \(contact.displayName)")
                        .font(.headline)
                    Text("Not yet on this hub's Matrix server")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Text("Share this registration link:")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text(registrationURL)
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(registrationURL, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(copied ? Color.green : Color.accentColor)
                }
                .buttonStyle(.bordered)
                .help("Copy link")
            }

            Text("Once they've created an account, add their Matrix ID to \(contact.displayName)'s note in your vault under the \u{2018}matrix_id\u{2019} field.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

// MARK: - New room sheet

private struct NewRoomSheet: View {
    let client: MatrixClient
    let onCreated: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var roomName = ""
    @State private var topic = ""
    @State private var isCreating = false
    @State private var error: String? = nil

    private var canCreate: Bool { !roomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Room")
                .font(.headline)

            LabeledContent("Name") {
                TextField("e.g. general", text: $roomName)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledContent("Topic") {
                TextField("Optional", text: $topic)
                    .textFieldStyle(.roundedBorder)
            }

            if let err = error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Button("Create") { create() }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCreate || isCreating)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func create() {
        let name = roomName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        isCreating = true
        error = nil
        Task {
            do {
                _ = try await client.createRoom(name: name, topic: topic.trimmingCharacters(in: .whitespacesAndNewlines))
                onCreated()
                dismiss()
            } catch {
                self.error = error.localizedDescription
                isCreating = false
            }
        }
    }
}

// MARK: - Message bubble

private struct MessageBubble: View {
    let message: MatrixMessage
    let myUserId: String

    private var isMe: Bool { message.sender == myUserId }
    private var senderShort: String {
        message.sender.components(separatedBy: ":").first.map {
            String($0.dropFirst())   // drop the @
        } ?? message.sender
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if isMe { Spacer(minLength: 40) }

            VStack(alignment: isMe ? .trailing : .leading, spacing: 2) {
                if !isMe {
                    Text(senderShort)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
                Text(message.body)
                    .font(.body)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(isMe ? Color.accentColor : Color(NSColor.controlBackgroundColor))
                    .foregroundStyle(isMe ? Color.white : Color.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }

            if !isMe { Spacer(minLength: 40) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }
}
