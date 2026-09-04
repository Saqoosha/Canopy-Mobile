import SwiftUI

/// Free text to one session. Deliberately not a chat: this app shows no
/// transcript, so a thread here would imply a history it cannot render.
struct ReplySheet: View {
    let machine: String
    let sessionId: String
    let sessionTitle: String
    /// The notification body being answered, when the sheet was opened from
    /// one — a completion's or an ask's `body`. Rendered read-only above the
    /// text field so the composer shows what it's replying to instead of
    /// making the user hold it in their head. `nil` (the roster-tap path
    /// with no matching history item) renders nothing extra.
    var context: String? = nil
    let send: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if let context, !context.isEmpty {
                    Section("Replying to") {
                        ScrollView {
                            Text(context)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 160)
                    }
                }
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
            // A 503 here means the reply DO found no publisher socket for
            // this machine — i.e. no Mac is connected. `RosterError.message`
            // can't say that generically: the roster-fetch path (RosterView's
            // `message(for:)`, over `MachineDirectory`/`RosterClient.fetch`)
            // also throws `.unexpectedStatus(503)`, but there it means the
            // relay itself is misconfigured (missing `SHARED_SECRET`) — an
            // unrelated cause that "no Mac is connected" would misdescribe.
            // So the reply-specific wording lives here, at the one call site
            // where a 503 is known to mean "the Mac is asleep."
            if case .unexpectedStatus(503) = e {
                error = "No Mac is connected — it may be asleep."
            } else {
                error = e.message
            }
        } catch {
            // The implicit `error` bound by this catch-all shadows the
            // `@State` property of the same name, so `self.` disambiguates.
            self.error = error.localizedDescription
        }
    }
}
