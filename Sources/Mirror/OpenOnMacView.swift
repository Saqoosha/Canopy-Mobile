import SwiftUI

/// Sheet that lists recent sessions and folders on a paired Mac, then opens one via attach.
struct OpenOnMacView: View {
    let target: MirrorTarget
    let machineName: String
    let onOpen: (String, OpenRequest, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var control: MachineControl
    @State private var tab: Tab = .sessions
    @State private var phase: Phase = .connecting
    @State private var sessions: [RecentSession] = []
    @State private var folders: [String] = []
    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var loadedSessions = false
    /// Why `list_folders` failed; shown in the Folders tab only, so the loaded sessions stay.
    @State private var foldersError: String?
    /// The Mac's No folder path, derived from its home directory; nil until known.
    @State private var noFolderPath: String?

    private enum Tab: String, CaseIterable, Identifiable {
        case sessions = "Sessions"
        case folders = "Folders"
        var id: String { rawValue }
    }

    private enum Phase {
        case connecting
        case ready
        case failed(String)
    }

    init(target: MirrorTarget, machineName: String, onOpen: @escaping (String, OpenRequest, String) -> Void) {
        self.target = target
        self.machineName = machineName
        self.onOpen = onOpen
        _control = State(initialValue: MachineControl(target: target))
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .connecting:
                    ProgressView("Connecting to \(machineName)…")
                case .failed(let message):
                    ContentUnavailableView("Can't open on Mac", systemImage: "wifi.exclamationmark",
                                           description: Text(message))
                case .ready:
                    readyContent
                }
            }
            .navigationTitle(machineName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task { await connectAndLoad() }
        .onDisappear {
            searchTask?.cancel()
            control.close()
        }
    }

    @ViewBuilder
    private var readyContent: some View {
        VStack(spacing: 0) {
            Picker("Browse", selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            switch tab {
            case .sessions:
                sessionsList
            case .folders:
                foldersList
            }
        }
    }

    private var sessionsList: some View {
        List(sessions) { row in
            Button {
                onOpen(row.resumeId, .resume, row.title)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Text("\(row.project) · \(relativeDate(row.lastActiveAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .listStyle(.plain)
        .overlay {
            if !loadedSessions {
                // The Mac lists its transcripts on the first ask, which takes a moment.
                ProgressView("Loading sessions…")
            } else if sessions.isEmpty {
                ContentUnavailableView(searchText.isEmpty ? "No recent sessions" : "No matches", systemImage: "clock")
            }
        }
        .searchable(text: $searchText, prompt: "Search sessions")
        .onChange(of: searchText) { _, _ in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await loadSessions(failSheet: false)
            }
        }
    }

    private var foldersList: some View {
        List {
            if let noFolderPath {
                Button {
                    onOpen(UUID().uuidString.lowercased(), .new(cwd: noFolderPath), RemoteFolder.noFolderName)
                } label: {
                    Label(RemoteFolder.noFolderName, systemImage: "bubble.left")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            NavigationLink {
                FolderBrowserView(control: control, startPath: browseRoot, onOpen: onOpen)
            } label: {
                Label("Browse…", systemImage: "folder")
            }
            if let foldersError {
                Label(foldersError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
            ForEach(folders, id: \.self) { path in
                NavigationLink {
                    FolderBrowserView(control: control, startPath: path, onOpen: onOpen)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text((path as NSString).lastPathComponent)
                            .font(.body.weight(.medium))
                        Text(path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    /// Parent of the first recent folder, or `/` when none are listed.
    private var browseRoot: String {
        guard let first = folders.first else { return "/" }
        let parent = (first as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    private func connectAndLoad() async {
        do {
            try await control.connect()
            phase = .ready
            // Folders are a quick read on the Mac; don't hold them behind the session scan.
            async let folders: Void = loadFolders()
            async let noFolder: Void = loadNoFolderPath()
            await loadSessions(failSheet: true)
            await folders
            await noFolder
        } catch let error as MachineControl.ControlError {
            phase = .failed(error.message)
        } catch {
            phase = .failed(MachineControl.ControlError.notReachable.message)
        }
    }

    /// A failed search keeps the sheet (and the last results); only the first load replaces it.
    private func loadSessions(failSheet: Bool) async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            var params: [String: Any] = ["scope": "recent", "limit": 50]
            if !query.isEmpty { params["query"] = query }
            let result = try await control.request("list_sessions", params)
            // An older query's answer must not replace a newer one's.
            guard query == searchText.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            sessions = RecentSession.list(from: result)
            loadedSessions = true
        } catch {
            guard failSheet || !loadedSessions else { return }
            phase = .failed((error as? MachineControl.ControlError)?.message ?? MachineControl.ControlError.notReachable.message)
        }
    }

    private func loadFolders() async {
        do {
            let result = try await control.request("list_folders", ["limit": 20])
            folders = (result["folders"] as? [String]) ?? []
        } catch {
            foldersError = "Can't list recent folders: " + ((error as? MachineControl.ControlError)?.message ?? MachineControl.ControlError.notReachable.message)
        }
    }

    /// `browse_dir` without a path answers with the Mac's home directory. Canopy 3.24.3+ creates
    /// No folder on open, so the path needs to exist only as a name here.
    private func loadNoFolderPath() async {
        do {
            let result = try await control.request("browse_dir", ["showHidden": false])
            noFolderPath = RemoteFolder.noFolderPath(home: result["path"] as? String)
        } catch {
            NSLog("[open-on-mac] no home directory for No folder: %@", String(describing: error))
        }
    }

    private func relativeDate(_ date: Date) -> String {
        SessionActivityStyle.published(since: Int(date.timeIntervalSince1970), now: Date())
    }
}

/// Directory browser over the Mac's `browse_dir` verb; directories push deeper, files stay dimmed.
struct FolderBrowserView: View {
    let control: MachineControl
    let onOpen: (String, OpenRequest, String) -> Void
    /// The folder of the browser screen this one was pushed from, if any.
    let previousPath: String?

    @Environment(\.dismiss) private var dismiss
    @State private var path: String
    /// The last folder that listed, so a failed move up can return to it.
    @State private var lastListedPath: String?
    @State private var phase: Phase = .loading
    @State private var entries: [DirEntry] = []
    @State private var showingNewFolder = false

    private enum Phase {
        case loading
        case ready
        case failed(String)
    }

    init(control: MachineControl, startPath: String, previousPath: String? = nil,
         onOpen: @escaping (String, OpenRequest, String) -> Void) {
        self.control = control
        self.onOpen = onOpen
        self.previousPath = previousPath.map(RemoteFolder.canonical)
        _path = State(initialValue: RemoteFolder.canonical(startPath))
    }

    private var folderTitle: String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView()
            case .failed(let message):
                ContentUnavailableView {
                    Label("Can't browse", systemImage: "folder.badge.questionmark")
                } description: {
                    Text(message)
                } actions: {
                    if let lastListedPath, lastListedPath != path {
                        Button("Back to \(RemoteFolder.displayName(of: lastListedPath))") {
                            phase = .loading
                            path = lastListedPath
                        }
                    }
                }
            case .ready:
                List {
                    if let parent = RemoteFolder.parent(of: path) {
                        // Back when the parent is the screen below; otherwise this screen moves up.
                        Button {
                            if parent == previousPath {
                                dismiss()
                            } else {
                                phase = .loading
                                path = parent
                            }
                        } label: {
                            Label(RemoteFolder.displayName(of: parent), systemImage: "arrow.turn.left.up")
                        }
                    }
                    ForEach(entries) { entry in
                        if entry.isDirectory {
                            NavigationLink {
                                FolderBrowserView(control: control, startPath: RemoteFolder.join(base: path, name: entry.name),
                                                  previousPath: path, onOpen: onOpen)
                            } label: {
                                Label(entry.name, systemImage: "folder")
                            }
                        } else {
                            Label(entry.name, systemImage: "doc")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(folderTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if case .ready = phase {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingNewFolder = true
                    } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showingNewFolder) {
            NewRemoteFolderSheet(parentPath: path, control: control) { createdPath, displayName in
                onOpen(UUID().uuidString.lowercased(), .new(cwd: createdPath), displayName)
            } onCreated: {
                Task { await load() }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if case .ready = phase {
                Button {
                    onOpen(UUID().uuidString.lowercased(), .new(cwd: path), folderTitle)
                } label: {
                    Text("New Session Here")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding()
                .background(.bar)
            }
        }
        .task(id: path) { await load() }
    }

    private func load() async {
        let requested = path
        do {
            let result = try await control.request("browse_dir", ["path": requested, "showHidden": false])
            guard requested == path else { return }
            entries = DirEntry.list(from: result)
            lastListedPath = requested
            phase = .ready
        } catch let error as MachineControl.ControlError {
            guard requested == path else { return }
            phase = .failed(error.message)
        } catch {
            guard requested == path else { return }
            phase = .failed(MachineControl.ControlError.notReachable.message)
        }
    }

}

/// Creates a directory on the paired Mac under the folder browser's current path.
private struct NewRemoteFolderSheet: View {
    let parentPath: String
    let control: MachineControl
    let onCreateAndOpen: (String, String) -> Void
    let onCreated: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool
    @State private var name = ""
    @State private var busy = false
    @State private var errorMessage: String?

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validationMessage: String? {
        RemoteFolder.validateName(name)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Folder name", text: $name)
                        .focused($nameFocused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Inside \(parentPath)")
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("New Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task { await create(startSession: false) }
                    }
                    .disabled(busy || validationMessage != nil)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    Task { await create(startSession: true) }
                } label: {
                    Text("Create & Start Session")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || validationMessage != nil)
                .padding()
                .background(.bar)
            }
            .interactiveDismissDisabled(busy)
            .task { nameFocused = true }
        }
        .presentationDetents([.medium])
    }

    private func create(startSession: Bool) async {
        if let validationMessage {
            errorMessage = validationMessage
            return
        }
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            let createdPath = try await control.createFolder(parentPath: parentPath, name: trimmedName)
            let displayName = (createdPath as NSString).lastPathComponent
            onCreated()
            dismiss()
            if startSession {
                onCreateAndOpen(createdPath, displayName.isEmpty ? trimmedName : displayName)
            }
        } catch let failure {
            errorMessage = RemoteFolder.createErrorMessage(failure)
        }
    }
}
