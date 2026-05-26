import SwiftUI

// MARK: - Root

struct ProcessListView: View {
    @StateObject private var store: CaseStore

    init(hub: HubStore) {
        _store = StateObject(wrappedValue: CaseStore(hub: hub))
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.isLoading && store.openCases.isEmpty && store.recentCases.isEmpty {
                    ProgressView("Connecting to cases service…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = store.errorMessage, store.openCases.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text("Could not reach cases service")
                            .font(.headline)
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Retry") { Task { await store.refresh() } }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    caseList
                }
            }
            .navigationTitle("Cases")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    HStack(spacing: 6) {
                        if !store.openCases.isEmpty {
                            Circle()
                                .fill(.green)
                                .frame(width: 7, height: 7)
                        }
                Text("\(store.openCases.count) active")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .automatic) {
                    Button(action: { Task { await store.refresh() } }) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .help("Refresh now")
                }
            }
            .navigationDestination(for: ProcessCase.self) { c in
                ProcessDetailView(processCase: c, store: store)
            }
        }
    }

    @ViewBuilder
    private var caseList: some View {
        List {
            if !store.openCases.isEmpty {
                Section("Active") {
                    ForEach(store.openCases) { c in
                        NavigationLink(value: c) {
                            ProcessRowView(processCase: c)
                        }
                    }
                }
            }

            if !store.recentCases.isEmpty {
                Section("Recent") {
                    ForEach(store.recentCases) { c in
                        NavigationLink(value: c) {
                            ProcessRowView(processCase: c)
                        }
                    }
                }
            }

            if store.openCases.isEmpty && store.recentCases.isEmpty {
                Text("No cases yet — submit a review to watch Frank work")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset)
    }
}

// MARK: - Case row

struct ProcessRowView: View {
    let processCase: ProcessCase

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                CaseStatusBadge(status: processCase.status)
                Text(processCase.processName ?? processCase.status)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(processCase.createdAt.formattedTimestamp)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if let sender = processCase.sender, !sender.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "person.circle")
                        .font(.caption2)
                    Text(sender)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(processCase.displayTitle)
                .font(.body)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Case status badge

struct CaseStatusBadge: View {
    let status: String

    var body: some View {
        Text(displayStatus)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(bg)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var displayStatus: String {
        switch status {
        case "COMPLETED": return "COMPLETE"
        case "IN_PROGRESS": return "IN PROGRESS"
        default: return status
        }
    }

    private var fg: Color {
        switch status {
        case "OPEN":                  return .yellow
        case "READY":                 return .accentColor
        case "IN_PROGRESS":           return .blue
        case "BLOCKED":               return .orange
        case "COMPLETE", "COMPLETED": return .green
        case "FAILED":                return .red
        default:         return .secondary
        }
    }

    private var bg: Color { fg.opacity(0.12) }
}
