import SwiftUI

/// Relay configuration, editable from inside the app — mirrors Pager's own
/// "Worker Configuration" section, with the commit rule taken from the
/// Canopy Mac app's relay-secret field instead of Pager's per-keystroke
/// write: submitting or tabbing away from the secret field is what commits
/// it to the Keychain, not every keystroke.
struct SettingsView: View {
    @Binding var rosterUrl: String
    @Binding var secret: String

    @Environment(\.dismiss) private var dismiss
    @FocusState private var secretFieldFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Relay") {
                    TextField("Relay URL", text: $rosterUrl)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Shared Secret", text: $secret)
                        .focused($secretFieldFocused)
                        .onSubmit { commitSecret() }
                        .onChange(of: secretFieldFocused) { _, focused in
                            // Clicking away must commit too, not just
                            // Return — otherwise a typed secret that the
                            // user taps past is silently discarded.
                            if !focused { commitSecret() }
                        }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func commitSecret() {
        KeychainHelper.save(key: "rosterSecret", value: secret)
    }
}
