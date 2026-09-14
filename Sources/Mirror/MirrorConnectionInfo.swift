import Foundation

/// The Mac's live-mirror address and password, as copied from Canopy's Settings.
struct MirrorConnectionInfo: Equatable {
    static let scheme = "canopy-mirror"

    let host: String
    let port: UInt16
    let token: String
    /// The Mac's roster machine id, so Live is offered only on its sessions; empty from an older Mac.
    let machine: String

    /// `host:port`, the form `MirrorConnectionStore` keeps per machine.
    var address: String { "\(host):\(port)" }

    /// Parses `canopy-mirror://<host>:<port>?token=<password>&machine=<id>`, tolerating surrounding whitespace.
    static func parse(_ text: String) -> MirrorConnectionInfo? {
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == scheme,
              let host = components.host, !host.isEmpty,
              let rawPort = components.port, let port = UInt16(exactly: rawPort), port != 0,
              let token = components.queryItems?.first(where: { $0.name == "token" })?.value, !token.isEmpty
        else { return nil }
        let machine = components.queryItems?.first(where: { $0.name == "machine" })?.value ?? ""
        return MirrorConnectionInfo(host: host, port: port, token: token, machine: machine)
    }
}
