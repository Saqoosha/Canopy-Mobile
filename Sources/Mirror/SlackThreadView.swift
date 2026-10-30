import SwiftUI

/// The session's Slack thread: open it, disconnect it, or connect one by its link.
struct SlackThreadSheet: View {
    let target: MirrorTarget
    /// The roster's `sessionId`, the Mac's key for the session.
    let sessionId: String
    let resumeId: String?
    let title: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var phase: Phase = .loading
    @State private var bindings: [SlackBinding] = []
    @State private var permalink = ""
    @State private var busy = false
    /// Why the last bind or unbind failed; the list stays.
    @State private var actionError: String?

    private enum Phase {
        case loading
        case ready
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    ProgressView("Loading Slack threads…")
                case .failed(let message):
                    ContentUnavailableView("Can't read Slack threads", systemImage: "wifi.exclamationmark",
                                           description: Text(message))
                case .ready:
                    form
                }
            }
            .navigationTitle("Slack thread")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    private var form: some View {
        Form {
            Section {
                if bindings.isEmpty {
                    Text("No Slack thread is connected to this session.")
                        .foregroundStyle(.secondary)
                }
                ForEach(bindings) { binding in
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            if let url = binding.threadURL { openURL(url) }
                        } label: {
                            Label("Open thread", systemImage: "arrow.up.right.square")
                        }
                        Text("Expires \(binding.expiresAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !bindings.isEmpty {
                    Button("Disconnect", role: .destructive) {
                        Task { for binding in bindings { await unbind(binding) } }
                    }
                    .disabled(busy)
                }
            } header: {
                Text(title)
            } footer: {
                Text("Replies in the thread reach this session through the Mac. Other people's replies run read-only.")
            }

            Section {
                TextField("Slack thread link", text: $permalink)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Connect") { Task { await bind() } }
                    .disabled(busy || permalink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text(bindings.isEmpty ? "Connect" : "Connect another")
            } footer: {
                Text("In Slack, use Copy link on the thread's first message. The link lasts 7 days.")
            }

            if let actionError {
                Section {
                    Label(actionError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// A connection per operation: the user may sit on the link field for a while.
    private func withControl<T>(_ body: (MachineControl) async throws -> T) async throws -> T {
        let control = MachineControl(target: target)
        defer { control.close() }
        try await control.connect()
        return try await body(control)
    }

    private func load() async {
        do {
            let all = try await withControl { try await $0.slackBindings() }
            bindings = all.filter { $0.belongs(sessionId: sessionId, resumeId: resumeId) }
            phase = .ready
        } catch {
            phase = .failed(SlackBinding.errorMessage(error))
        }
    }

    private func bind() async {
        busy = true
        defer { busy = false }
        actionError = nil
        do {
            try await withControl { try await $0.slackBind(key: sessionId, resumeId: resumeId, permalink: permalink) }
            permalink = ""
            await load()
        } catch {
            actionError = SlackBinding.errorMessage(error)
        }
    }

    private func unbind(_ binding: SlackBinding) async {
        busy = true
        defer { busy = false }
        actionError = nil
        do {
            try await withControl { try await $0.slackUnbind(binding) }
            bindings.removeAll { $0.id == binding.id }
        } catch {
            actionError = SlackBinding.errorMessage(error)
        }
    }
}

/// The toolbar button that opens `SlackThreadSheet`. Nothing when no paste covers the Mac.
struct SlackThreadButton: View {
    let target: MirrorTarget?
    let sessionId: String
    let resumeId: String?
    let title: String

    @State private var showing = false

    var body: some View {
        if let target {
            Button {
                showing = true
            } label: {
                Image(systemName: "bubble.left.and.text.bubble.right")
            }
            .accessibilityLabel("Slack thread")
            .sheet(isPresented: $showing) {
                SlackThreadSheet(target: target, sessionId: sessionId, resumeId: resumeId, title: title)
            }
        }
    }
}
