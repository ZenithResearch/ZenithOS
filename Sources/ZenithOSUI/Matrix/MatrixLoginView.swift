import SwiftUI

struct MatrixLoginView: View {
    let homeserver: String
    let onLogin:    (String, String) async throws -> Void
    let onRegister: (String, String) async throws -> Void

    enum Mode { case signIn, createAccount }

    @State private var mode:     Mode   = .signIn
    @State private var user:     String = ""
    @State private var password: String = ""
    @State private var confirm:  String = ""
    @State private var isLoading    = false
    @State private var errorMessage: String? = nil

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text(mode == .signIn ? "Sign In" : "Create Account")
                    .font(.headline)
                Text(homeserver)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            // Mode picker
            Picker("", selection: $mode) {
                Text("Sign In").tag(Mode.signIn)
                Text("Create Account").tag(Mode.createAccount)
            }
            .pickerStyle(.segmented)
            .onChange(of: mode) { _ in errorMessage = nil }

            Divider()

            // Fields
            VStack(alignment: .leading, spacing: 12) {
                LabeledField(label: mode == .signIn ? "Username or Matrix ID" : "Username") {
                    TextField(mode == .signIn ? "@user:localhost" : "username", text: $user)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }
                LabeledField(label: "Password") {
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                }
                if mode == .createAccount {
                    LabeledField(label: "Confirm Password") {
                        SecureField("Confirm Password", text: $confirm)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }

            if let err = errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // Actions
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: submit) {
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(mode == .signIn ? "Sign In" : "Create Account")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit || isLoading)
                .keyboardShortcut(.return)
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    private var canSubmit: Bool {
        guard !user.isEmpty && !password.isEmpty else { return false }
        if mode == .createAccount { return password == confirm && !confirm.isEmpty }
        return true
    }

    private func submit() {
        errorMessage = nil
        isLoading = true
        Task {
            do {
                if mode == .signIn {
                    try await onLogin(user, password)
                } else {
                    try await onRegister(user, password)
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}

// MARK: - Helper

private struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            content()
        }
    }
}
