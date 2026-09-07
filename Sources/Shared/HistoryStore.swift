import Foundation

/// Read/write API for notification history, backed by per-entry JSON files
/// inside the App Group container.
///
/// Writers:
/// - The Notification Service Extension calls `append` when a push arrives.
/// - The main app calls `updateDecision` when the user acts on Allow/Deny.
/// These two writers never target the same file (append creates a new file,
/// updateDecision overwrites an existing one), so writes don't collide.
/// `pruneOldFiles` may race with either writer in rare cases; deletions are
/// best-effort and tolerate already-removed files.
enum HistoryStore {
    static let appGroupID = "group.sh.saqoo.canopy-app"
    /// Pager's number, adopted here without re-deriving it — not a
    /// considered choice for this app's own usage pattern.
    static let maxItems = 100

    enum StoreError: Error, LocalizedError {
        case containerUnavailable
        /// `updateDecision` was handed a `requestId` with no file behind it.
        ///
        /// **Thrown rather than returned as a silent no-op, and that is the
        /// fix.** The old shape returned quietly, which meant the entry kept
        /// `decision == nil` — so `MessageBlock` went on drawing the ask as
        /// unanswered and the user could answer it again, with nothing on
        /// screen or in the log saying the record had not been written.
        case entryNotFound(requestId: String)

        var errorDescription: String? {
            switch self {
            case .containerUnavailable:
                return "The app group container is unavailable"
            case .entryNotFound(let requestId):
                return "No history entry for requestId \(requestId)"
            }
        }
    }

    static func containerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    static func historyDirectory() throws -> URL {
        guard let container = containerURL() else {
            throw StoreError.containerUnavailable
        }
        let dir = container.appendingPathComponent("history", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    // `ISO8601DateFormatter.string(from:)` / `date(from:)` are documented as
    // thread-safe, so sharing one instance across callers (main app + NSE) is
    // safe. Swift 6 cannot prove this from the type, hence `nonisolated(unsafe)`.
    nonisolated(unsafe) private static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let iso8601Plain: ISO8601DateFormatter = {
        ISO8601DateFormatter()
    }()

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        // Fractional seconds preserve the millisecond precision used in filenames,
        // so a round-trip through JSON does not drift the derived filename.
        e.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(iso8601Fractional.string(from: date))
        }
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            if let date = iso8601Fractional.date(from: str) { return date }
            if let date = iso8601Plain.date(from: str) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO8601 date: \(str)"
            )
        }
        return d
    }

    private static func filename(for item: NotificationHistoryItem) -> String {
        let millis = Int64(item.receivedAt.timeIntervalSince1970 * 1000)
        return "\(millis)-\(item.id).json"
    }

    /// Called by the Notification Service Extension when a push arrives.
    static func append(_ item: NotificationHistoryItem) throws {
        let dir = try historyDirectory()
        let url = dir.appendingPathComponent(filename(for: item))
        let data = try encoder().encode(item)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        // Pruning is best-effort: a failure here must not mask the successful write.
        do {
            try pruneOldFiles(in: dir)
        } catch {
            NSLog("HistoryStore: pruneOldFiles failed: \(error)")
        }
        HistoryUpdateBridge.postDarwinUpdate()
    }

    /// Loads all history entries, newest first.
    static func loadAll() throws -> [NotificationHistoryItem] {
        let dir = try historyDirectory()
        let files = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        )
        let dec = decoder()
        var items: [NotificationHistoryItem] = []
        for file in files where file.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: file)
                items.append(try dec.decode(NotificationHistoryItem.self, from: data))
            } catch {
                NSLog("HistoryStore: skipping unreadable entry \(file.lastPathComponent): \(error)")
                continue
            }
        }
        items.sort { $0.receivedAt > $1.receivedAt }
        return items
    }

    static func item(withId id: String) throws -> NotificationHistoryItem? {
        try loadAll().first(where: { $0.id == id })
    }

    static func delete(id: String) throws {
        let dir = try historyDirectory()
        let files = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        )
        for file in files where file.lastPathComponent.hasSuffix("-\(id).json") {
            try FileManager.default.removeItem(at: file)
        }
    }

    static func deleteAll() throws {
        let dir = try historyDirectory()
        let files = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        )
        for file in files {
            try FileManager.default.removeItem(at: file)
        }
    }

    /// Updates `decision` / `decidedAt` for the entry with a matching requestId.
    /// Called after the user acts on Allow or Deny — from the app's detail
    /// view, or from `PushRegistrar` when the action came off the lock screen.
    /// Those two are the only decisions the relay accepts; Pager's third,
    /// "Allow Always", is out of scope and no caller can produce it.
    ///
    /// Throws `StoreError.entryNotFound` when nothing matches — which is what
    /// a pruned entry looks like, and also what a genuine id mismatch looks
    /// like. The two are not worth telling apart here; what matters is that
    /// neither is silent, because both leave the ask drawn as unanswered.
    static func updateDecision(requestId: String, decision: String, decidedAt: Date,
                               delivered: Bool) throws {
        // Look up the file by id rather than recomputing the filename from
        // the loaded item — that would require preserving receivedAt at full
        // precision through JSON and filesystem round-trips.
        let dir = try historyDirectory()
        let files = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        )
        guard let url = files.first(where: { $0.lastPathComponent.hasSuffix("-\(requestId).json") }) else {
            throw StoreError.entryNotFound(requestId: requestId)
        }
        let data = try Data(contentsOf: url)
        var item = try decoder().decode(NotificationHistoryItem.self, from: data)
        item.decision = decision
        item.decidedAt = decidedAt
        item.decisionDelivered = delivered
        let newData = try encoder().encode(item)
        try newData.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        HistoryUpdateBridge.postDarwinUpdate()
    }

    private static func pruneOldFiles(in dir: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )
        guard files.count > maxItems else { return }
        // `filename(for:)` emits `<millis>-<id>.json`, so lexicographic order
        // matches chronological order. If you change the filename format,
        // revisit this sort.
        let sorted = files.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let excess = sorted.count - maxItems
        for i in 0..<excess {
            try? FileManager.default.removeItem(at: sorted[i])
        }
    }
}
