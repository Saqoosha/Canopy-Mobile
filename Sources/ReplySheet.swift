import SwiftUI

/// Free text to one session. Deliberately not a chat: this app shows no
/// transcript, so a thread here would imply a history it cannot render.
struct ReplySheet: View {
    let machine: String
    let sessionId: String
    let sessionTitle: String
    let send: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section(sessionTitle) {
                    TextField("What should it do next?", text: $text, axis: .vertical)
                        .lineLimit(3...8)
                    if let error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Reply")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { Task { await submit() } }
                        .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func submit() async {
        sending = true
        defer { sending = false }
        do {
            try await send(text.trimmingCharacters(in: .whitespacesAndNewlines))
            dismiss()
        } catch let e as RosterError {
            error = e.message
        } catch {
            // The implicit `error` bound by this catch-all shadows the
            // `@State` property of the same name, so `self.` disambiguates.
            self.error = error.localizedDescription
        }
    }
}
