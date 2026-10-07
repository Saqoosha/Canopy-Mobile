import Foundation

/// Where a kept page stands, sent back as `since` + `channelId` so the Mac replays only the frames it missed
/// (Canopy PR #321). The Mac refuses any point it cannot serve, and the page is then rebuilt as before.
struct MirrorResumePoint: Equatable {
    let epoch: String
    let seq: Int
    /// The page's own channel, from its latest `launch_claude`.
    let channelId: String
}

/// Follows one link's frames and the page's requests to know whether its page could resume on a new link.
struct MirrorResumeTracker: Equatable {
    private(set) var epoch: String?
    /// The highest seq handed to the page; frames still held behind the prefetch do not count.
    private(set) var seq: Int?
    private(set) var channelId: String?
    /// Requests the page sent that have no response yet. Their owner on the Mac dies with this link,
    /// so a page waiting on one must not resume.
    private(set) var pendingRequests: Set<String> = []
    private(set) var transcriptDelivered = false

    /// A Mac older than PR #321 sends no epoch, and every point stays nil.
    /// `resumedFrom` is the point a resumed attach sent: the kept page holds its transcript and keeps its channel.
    mutating func noteAttached(_ attachOK: [String: Any], resumedFrom: MirrorResumePoint?) {
        epoch = (attachOK["epoch"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        seq = Self.integer(attachOK["seq"])
        if let resumedFrom {
            transcriptDelivered = true
            channelId = resumedFrom.channelId
            // The missed frames follow and advance it; the page holds nothing past this yet.
            seq = resumedFrom.seq
        }
    }

    /// One frame handed to the page.
    mutating func noteDelivered(_ frame: [String: Any]) {
        if let frameSeq = Self.integer(frame["seq"]) { seq = max(seq ?? frameSeq, frameSeq) }
        if let message = frame["message"] as? [String: Any], message["type"] as? String == "response",
           let requestId = message["requestId"] as? String {
            pendingRequests.remove(requestId)
        }
    }

    /// One message the page sent to the Mac.
    mutating func noteSent(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "launch_claude":
            if let cid = message["channelId"] as? String, !cid.isEmpty { channelId = cid }
        case "request":
            if let requestId = message["requestId"] as? String { pendingRequests.insert(requestId) }
        default:
            break
        }
    }

    mutating func noteTranscriptDelivered() {
        transcriptDelivered = true
    }

    var point: MirrorResumePoint? {
        guard transcriptDelivered, pendingRequests.isEmpty, let epoch, let seq, let channelId else { return nil }
        return MirrorResumePoint(epoch: epoch, seq: seq, channelId: channelId)
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.intValue
    }
}
