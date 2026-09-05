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
    @State private var hasStoredSecret = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Relay") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Relay URL").font(.caption).foregroundStyle(.secondary)
                        TextField("https://relay.example.com", text: $rosterUrl)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityLabel("Relay URL")
                    }
                    .padding(.vertical, 4)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Shared secret").font(.caption).foregroundStyle(.secondary)
                        SecureField("Shared secret", text: $secret)
                        .focused($secretFieldFocused)
                        .onSubmit { commitSecret() }
                        .onChange(of: secretFieldFocused) { _, focused in
                            // Clicking away must commit too, not just
                            // Return — otherwise a typed secret that the
                            // user taps past is silently discarded.
                            if !focused { commitSecret() }
                        }
                    }
                    .padding(.vertical, 4)
                    // Never reveals the value — but the field IS seeded from
                    // the Keychain, so it is not empty on a revisit, and a
                    // paste into it appends rather than replaces unless the
                    // user selects the existing content first. This Text only
                    // tells the user something is stored, not what it is.
                    Label(hasStoredSecret ? "A secret is stored" : "No secret stored", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    // Blank submit is a deliberate no-op, and the Keychain
                    // item survives app uninstall — without this there is
                    // no path to remove a bad stored secret.
                    if hasStoredSecret {
                        Button("Clear stored secret", role: .destructive) {
                            if !CanopyDemo.isEnabled { KeychainHelper.delete(key: "rosterSecret") }
                            secret = ""
                            hasStoredSecret = KeychainHelper.has(key: "rosterSecret")
                        }
                    }
                }
                if CanopyDemo.isEnabled {
                    Section {
                        Label("Demo mode", systemImage: "iphone")
                    } footer: {
                        Text("Sample data only. Settings, replies and permission decisions are not saved or sent to a relay.")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { commitSecret(); dismiss() }
                }
            }
            .onAppear { hasStoredSecret = !CanopyDemo.isEnabled && KeychainHelper.has(key: "rosterSecret") }
        }
    }

    /// A blank submit is the ordinary result of tabbing through the form
    /// with the never-seeded, always-blank-looking `SecureField` untouched
    /// — it must be a no-op, never a delete, or every visit to Settings
    /// risks silently wiping a working secret. `KeychainHelper.save` itself
    /// stays unguarded (Pager relies on its current unconditional
    /// behaviour); the guard belongs here, at the call site that actually
    /// means "the user typed a new secret."
    ///
    /// The demo guard is here too, not only on the indicator: the URL field
    /// is bound to a throwaway `@State` but the secret field keeps the real
    /// binding, so a keystroke during a demo run overwrote the simulator's
    /// stored secret and the next real launch could not authenticate.
    private func commitSecret() {
        guard !CanopyDemo.isEnabled, !secret.isEmpty else { return }
        KeychainHelper.save(key: "rosterSecret", value: secret)
        hasStoredSecret = KeychainHelper.has(key: "rosterSecret")
    }
}
