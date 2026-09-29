import Foundation

/// A closed or running session the Mac's control API listed under `list_sessions`.
struct RecentSession: Identifiable, Equatable {
    let resumeId: String
    let title: String
    let project: String
    let cwd: String
    let lastActiveAt: Date

    var id: String { resumeId }

    /// Rows whose `resumeId` is missing are skipped; an empty title becomes "Untitled".
    static func list(from result: [String: Any]) -> [RecentSession] {
        guard let rows = result["sessions"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let resumeId = row["resumeId"] as? String, !resumeId.isEmpty else { return nil }
            let rawTitle = row["title"] as? String
            let title = (rawTitle?.isEmpty == false) ? rawTitle! : "Untitled"
            return RecentSession(
                resumeId: resumeId,
                title: title,
                project: row["project"] as? String ?? "",
                cwd: row["cwd"] as? String ?? "",
                lastActiveAt: Self.date(from: row["lastActiveAt"])
            )
        }
    }

    private static func date(from value: Any?) -> Date {
        if let number = value as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        if let double = value as? Double {
            return Date(timeIntervalSince1970: double)
        }
        if let int = value as? Int {
            return Date(timeIntervalSince1970: Double(int))
        }
        return Date(timeIntervalSince1970: 0)
    }
}

/// One name in a `browse_dir` listing.
struct DirEntry: Identifiable, Equatable {
    let name: String
    let isDirectory: Bool

    var id: String { name }

    static func list(from result: [String: Any]) -> [DirEntry] {
        guard let rows = result["entries"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let name = row["name"] as? String, !name.isEmpty else { return nil }
            return DirEntry(name: name, isDirectory: row["isDirectory"] as? Bool ?? false)
        }
    }
}

/// What the attach's optional `open` field asks the Mac to do.
enum OpenRequest: Equatable {
    case resume
    case new(cwd: String)

    var wire: [String: Any] {
        switch self {
        case .resume:
            ["kind": "resume"]
        case .new(let cwd):
            ["kind": "new", "cwd": cwd, "options": [String: Any]()]
        }
    }
}
