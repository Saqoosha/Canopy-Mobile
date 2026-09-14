import SwiftUI

/// Relay configuration, editable from inside the app — mirrors Pager's own
/// "Worker Configuration" section, with the commit rule taken from the
/// Canopy Mac app's relay-secret field instead of Pager's per-keystroke
/// write: submitting or tabbing away from the secret field is what commits
/// it to the Keychain, not every keystroke.
struct SettingsView: View {
    @Binding var rosterUrl: String
    @Binding var secret: String
    /// The Macs whose sessions open live; pastes add to it, Forget removes from it.
    let mirrorStore: MirrorConnectionStore
    /// The roster's name per machine id, so a stored Mac is labelled by name rather than UUID.
    let machineNames: [String: String]
    /// Whether the secure field has been typed into since this sheet opened.
    /// `secret` is seeded from the Keychain, so every commit path — Return,
    /// tabbing away, Done — otherwise re-saves a value that is already there,
    /// and `KeychainHelper.save` is delete-then-add: an add that fails during
    /// that pointless rewrite removes the credential that was working.
    @State private var secretEdited = false

    @Environment(\.dismiss) private var dismiss
    @FocusState private var secretFieldFocused: Bool
    @State private var hasStoredSecret = false
    @State private var mirrorPasteError: String?

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
                        .onChange(of: secret) { _, _ in secretEdited = true }
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
                Section {
                    if mirrorStore.isEmpty {
                        Label("Not set up", systemImage: "rectangle.on.rectangle.slash")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(mirrorStore.entries.machines, id: \.self) { machine in
                        HStack {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(machineNames[machine] ?? (machine.isEmpty ? "Any Mac" : machine))
                                    Text(mirrorStore.entries.address(for: machine) ?? "")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "rectangle.on.rectangle")
                            }
                            Spacer()
                            Button("Forget", role: .destructive) {
                                mirrorPasteError = nil
                                mirrorStore.forget(machine: machine)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    Button("Paste Connection from Mac") { pasteMirrorConnection() }
                    if let mirrorPasteError {
                        Text(mirrorPasteError).font(.caption).foregroundStyle(.red)
                    }
                } header: {
                    Text("Live mirror")
                } footer: {
                    Text("In Canopy on the Mac, open Settings › Mobile, turn on “Let the iPhone open live sessions” and choose Copy Connection for iPhone. Each Mac is stored separately; a session opens live when its Mac answers, and shows the last known conversation when it does not. Both devices must be on the same tailnet.")
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
        guard secretEdited, !CanopyDemo.isEnabled, !secret.isEmpty else { return }
        KeychainHelper.save(key: "rosterSecret", value: secret)
        hasStoredSecret = KeychainHelper.has(key: "rosterSecret")
        secretEdited = false
    }

    private func pasteMirrorConnection() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            mirrorPasteError = "Nothing to paste. Copy the connection in Canopy on the Mac, then allow the paste."
            return
        }
        guard let info = MirrorConnectionInfo.parse(text) else {
            mirrorPasteError = "That is not a Canopy connection (expected canopy-mirror://…)."
            return
        }
        // The demo store is inert, so a demo run cannot touch the real Keychain or table.
        let status = mirrorStore.save(info)
        guard status == errSecSuccess else {
            mirrorPasteError = "Could not store the password (\(status))."
            return
        }
        mirrorPasteError = nil
    }
}
