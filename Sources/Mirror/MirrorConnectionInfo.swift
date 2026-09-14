import Foundation

/// The Mac's live-mirror address and password, as copied from Canopy's Settings.
struct MirrorConnectionInfo: Equatable {
    static let scheme = "canopy-mirror"
    static let tokenKeychainKey = "mirrorToken"

    let host: String
    let port: UInt16
    let token: String

    /// `host:port`, the form stored in `@AppStorage("mirrorAddress")`.
    var address: String { "\(host):\(port)" }

    /// Parses `canopy-mirror://<host>:<port>?token=<password>`, tolerating surrounding whitespace.
    static func parse(_ text: String) -> MirrorConnectionInfo? {
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == scheme,
              let host = components.host, !host.isEmpty,
              let rawPort = components.port, let port = UInt16(exactly: rawPort), port != 0,
              let token = components.queryItems?.first(where: { $0.name == "token" })?.value, !token.isEmpty
        else { return nil }
        return MirrorConnectionInfo(host: host, port: port, token: token)
    }
}
