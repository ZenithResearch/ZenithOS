import SwiftUI

struct TodoWidget: View {
    @StateObject private var store = TodoStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Today", systemImage: "checkmark.square")
                    .font(.headline)
                Spacer()
                if store.isLoading {
                    ProgressView().scaleEffect(0.7)
                } else {
                    Text("\(store.todos.filter { $0.status == "done" }.count)/\(store.todos.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if store.todos.isEmpty && !store.isLoading {
                Text("No to-dos for today")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(store.todos) { item in
                        TodoRow(item: item) {
                            Task { await store.toggle(item) }
                        }
                    }
                }
            }
        }
        .task { await store.loadToday() }
    }
}

// MARK: - Row

struct TodoRow: View {
    let item: TodoItem
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: item.status == "done"
                      ? "checkmark.square.fill"
                      : "square")
                    .foregroundStyle(item.status == "done" ? .green : .secondary)
                    .font(.body)

                Text(item.title)
                    .font(.body)
                    .foregroundStyle(item.status == "done" ? .secondary : .primary)
                    .strikethrough(item.status == "done", color: .secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let arena = item.arena.first, !arena.isEmpty {
                    Text(arena)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
