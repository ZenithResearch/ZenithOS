import SwiftUI

struct FloatingGlassTextBox: View {
    @ObservedObject var overlay: FloatingGlassOverlay
    @FocusState private var textFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Zenith")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer()
                Text(overlay.isSending ? "thinking..." : "⌘↩ submit")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.52))
            }

            ZStack(alignment: .topLeading) {
                if overlay.draftText.isEmpty {
                    Text("Ask, route, or capture a thought...")
                        .font(.system(size: 24, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.34))
                        .padding(.horizontal, 5)
                        .padding(.top, 8)
                }

                TextEditor(text: $overlay.draftText)
                    .font(.system(size: 24, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .focused($textFocused)
                    .frame(minHeight: 88, maxHeight: 112)
                    .onSubmit {
                        overlay.submit()
                    }
            }

            HStack(spacing: 10) {
                Button("Clear") {
                    overlay.clear()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.62))
                .disabled(overlay.draftText.isEmpty && overlay.lastSubmitted == nil)

                Spacer()

                if let submitted = overlay.lastSubmitted {
                    Text(submitted)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.46))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Button {
                    overlay.submit()
                } label: {
                    Text(overlay.isSending ? "Sending" : "Submit")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(.white.opacity(0.16))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [.command])
                .foregroundStyle(.white)
                .disabled(overlay.isSending || overlay.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .font(.system(size: 13, weight: .medium, design: .rounded))

            if overlay.isSending {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.8))
            } else if let error = overlay.errorMessage {
                Text(error)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.red.opacity(0.82))
                    .lineLimit(3)
                    .textSelection(.enabled)
            } else if !overlay.responseText.isEmpty {
                ScrollView {
                    Text(overlay.responseText)
                        .font(.system(size: 15, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.88))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            }
        }
        .padding(22)
        .frame(width: 680, height: 420)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.20),
                                .cyan.opacity(0.08),
                                .pink.opacity(0.08),
                                .black.opacity(0.18)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .strokeBorder(.white.opacity(0.28), lineWidth: 1)
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .strokeBorder(.black.opacity(0.22), lineWidth: 1)
                    .blur(radius: 0.4)
            }
        }
        .shadow(color: .black.opacity(0.24), radius: 34, x: 0, y: 22)
        .padding(12)
        .onAppear {
            textFocused = true
        }
    }
}
