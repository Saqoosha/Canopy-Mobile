import Foundation

/// Read/write API for notification history, backed by per-entry JSON files
/// inside the App Group container.
///
/// Writers:
/// - The Notification Service Extension calls `append` when a push arrives.
/// - The main app calls `append` too, for the local record of a reply typed
///   on this phone (`SessionConversationView`).
/// - The main app calls `updateDecision` when the user acts on Allow/Deny.
/// `append` and `updateDecision` never target the same file (append creates a
/// new one under a fresh id, updateDecision overwrites existing ones), so
/// writes don't collide from either process.
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

    /// The App Group directory the entries live in.
    ///
    /// **Every operation below also has a form that takes its directory, and
    /// that is the seam.** `containerURL()` asks the system for a container
    /// this process is entitled to, which a host-less test bundle is not — so
    /// without the pair, none of this file could be reached from a test at
    /// all. The one bug these functions have had (`updateDecision` stopping at
    /// the first unreadable duplicate) was found by reading the code and
    /// confirmed on a device, which is the slowest place there is to find one.
    ///
    /// The no-argument forms are the whole app: nothing outside tests passes a
    /// directory, so there is no second configuration to keep working.
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
        try append(item, in: historyDirectory())
    }

    /// - Parameter dir: an existing directory. See `historyDirectory()`.
    static func append(_ item: NotificationHistoryItem, in dir: URL) throws {
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
        try loadAll(in: historyDirectory())
    }

    /// - Parameter dir: an existing directory. See `historyDirectory()`.
    static func loadAll(in dir: URL) throws -> [NotificationHistoryItem] {
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
        try item(withId: id, in: historyDirectory())
    }

    /// - Parameter dir: an existing directory. See `historyDirectory()`.
    static func item(withId id: String, in dir: URL) throws -> NotificationHistoryItem? {
        try loadAll(in: dir).first(where: { $0.id == id })
    }

    static func delete(id: String) throws {
        try delete(id: id, in: historyDirectory())
    }

    /// - Parameter dir: an existing directory. See `historyDirectory()`.
    static func delete(id: String, in dir: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        )
        for file in files where file.lastPathComponent.hasSuffix("-\(id).json") {
            try FileManager.default.removeItem(at: file)
        }
    }

    static func deleteAll() throws {
        try deleteAll(in: historyDirectory())
    }

    /// - Parameter dir: an existing directory. See `historyDirectory()`.
    static func deleteAll(in dir: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        )
        for file in files {
            try FileManager.default.removeItem(at: file)
        }
    }

    /// Updates `decision` / `decidedAt` for every entry with a matching
    /// requestId. Called after the user resolves an ask — Allow, Deny, Always,
    /// or an answered `AskUserQuestion` — from `CanopyMobileApp.sendDecision`,
    /// or from `PushRegistrar` when the action came off the lock screen.
    /// **What is STORED here is not always what went on the wire.** The relay
    /// takes an action identifier — `allow`, `deny` or `allowAlways` — and
    /// that is what `RosterClient.sendDecision` posts. This function records
    /// `recordAs` when the caller supplies one, which for an answered
    /// `AskUserQuestion` is the labels the user picked, so a stored `decision`
    /// can read "Postgres · main". One is the protocol, the other is what the
    /// person did; `CanopyMobileApp.sendDecision` is where they part. Reading
    /// this field as a three-value enum would break every answered form.
    ///
    /// Throws `StoreError.entryNotFound` when nothing matches — which is what
    /// a pruned entry looks like, and also what a genuine id mismatch looks
    /// like. The two are not worth telling apart here; what matters is that
    /// neither is silent, because both leave the ask drawn as unanswered.
    static func updateDecision(requestId: String, decision: String, decidedAt: Date,
                               delivered: Bool) throws {
        try updateDecision(requestId: requestId, decision: decision, decidedAt: decidedAt,
                           delivered: delivered, in: historyDirectory())
    }

    /// - Parameter dir: an existing directory. See `historyDirectory()`.
    static func updateDecision(requestId: String, decision: String, decidedAt: Date,
                               delivered: Bool, in dir: URL) throws {
        // Look up the file by id rather than recomputing the filename from
        // the loaded item — that would require preserving receivedAt at full
        // precision through JSON and filesystem round-trips.
        let files = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        )
        // **Every match, not the first one.** `append` writes
        // `<millis>-<id>.json` and does not deduplicate, so nothing guarantees
        // one file per `requestId` — two deliveries of one ask are two files
        // with the same suffix and different millis. Updating only the first
        // left the other at `decision == nil`, which `MessageBlock` draws as
        // an unanswered ask: the exact "I answered it and it is still asking"
        // this function's throw exists to make visible, arriving by a route
        // where nothing throws because one file WAS found. `contentsOfDirectory`
        // promises no order, so which copy won was not even stable.

        let matches = files.filter { $0.lastPathComponent.hasSuffix("-\(requestId).json") }
        guard !matches.isEmpty else {
            throw StoreError.entryNotFound(requestId: requestId)
        }
        // **Per file, and the isolation is the point.** A `try` straight
        // through the loop aborted it on the first unreadable duplicate,
        // leaving the earlier files updated, the later ones at
        // `decision == nil`, and — because the broadcast sits after the loop —
        // NOTHING told to reload. That reproduces this function's own bug
        // through the fix for it. `loadAll` already logs and continues past an
        // entry it cannot decode; a writer that dies on one is the asymmetry.
        var updated = 0
        var firstFailure: Error?
        for url in matches {
            do {
                let data = try Data(contentsOf: url)
                var item = try decoder().decode(NotificationHistoryItem.self, from: data)
                item.decision = decision
                item.decidedAt = decidedAt
                item.decisionDelivered = delivered
                let newData = try encoder().encode(item)
                try newData.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                updated += 1
            } catch {
                if firstFailure == nil { firstFailure = error }
                NSLog("HistoryStore.updateDecision: could not update %@ for requestId=%@: %@",
                      url.lastPathComponent, requestId, String(describing: error))
            }
        }
        // Announce whatever landed; throw only when nothing did. `matches` is
        // non-empty, and each pass either counts or records, so `updated == 0`
        // guarantees a `firstFailure` — the throw cannot fall through.
        //
        // **A PARTIAL failure returns normally, and the caller is not told.**
        // The two conditions below are mutually exclusive, so there is no path
        // that both announces and throws. With two duplicates where one write
        // fails, the survivor keeps `decision == nil`, still decodes, and is
        // still drawn as an unanswered ask — this function's own symptom,
        // reached without an error. It is logged per file above and nowhere
        // else. Reporting it needs a case carrying the counts, which is a
        // contract change for both callers.
        if updated > 0 { HistoryUpdateBridge.postDarwinUpdate() }
        if updated == 0, let firstFailure { throw firstFailure }
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
