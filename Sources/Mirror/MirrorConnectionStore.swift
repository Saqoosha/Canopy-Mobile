import Foundation
import Observation

/// The Macs whose live mirror this phone can open, one entry per roster machine id.
///
/// Addresses live in UserDefaults as one JSON object; each Mac's password is
/// its own Keychain item, because every Mac mints its own.
@MainActor
@Observable
final class MirrorConnectionStore {
    static let defaultsKey = "mirrorConnections"
    /// The pre-2026-09-14 single-Mac keys, read once and then removed.
    static let legacyAddressKey = "mirrorAddress"
    static let legacyMachineKey = "mirrorMachine"
    static let legacyTokenKey = "mirrorToken"

    private(set) var entries: MirrorConnectionEntries
    /// nil is the demo store: starts empty, never touches UserDefaults or the Keychain.
    private let defaults: UserDefaults?

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        guard let defaults else { entries = MirrorConnectionEntries(); return }
        var loaded = MirrorConnectionEntries(json: defaults.string(forKey: Self.defaultsKey))
        if let legacyAddress = defaults.string(forKey: Self.legacyAddressKey), !legacyAddress.isEmpty {
            let machine = defaults.string(forKey: Self.legacyMachineKey) ?? ""
            loaded = loaded.adding(machine: machine, address: legacyAddress)
            if let token = KeychainHelper.load(key: Self.legacyTokenKey) {
                _ = KeychainHelper.save(key: Self.tokenKey(for: machine), value: token)
                KeychainHelper.delete(key: Self.legacyTokenKey)
            }
            defaults.removeObject(forKey: Self.legacyAddressKey)
            defaults.removeObject(forKey: Self.legacyMachineKey)
            defaults.set(loaded.json, forKey: Self.defaultsKey)
        }
        entries = loaded
    }

    static func tokenKey(for machine: String) -> String { "mirrorToken.\(machine)" }

    var isEmpty: Bool { entries.isEmpty }

    /// The address and password to attach to `machine`'s sessions with, or nil when no paste covers it.
    func target(for machine: String) -> MirrorTarget? {
        guard defaults != nil, let match = entries.match(for: machine),
              let token = KeychainHelper.load(key: Self.tokenKey(for: match.machine)), !token.isEmpty
        else { return nil }
        return MirrorTarget(address: match.address, token: token)
    }

    func save(_ info: MirrorConnectionInfo) -> OSStatus {
        guard let defaults else { return errSecSuccess }
        let status = KeychainHelper.save(key: Self.tokenKey(for: info.machine), value: info.token)
        guard status == errSecSuccess else { return status }
        entries = entries.adding(machine: info.machine, address: info.address)
        defaults.set(entries.json, forKey: Self.defaultsKey)
        return status
    }

    func forget(machine: String) {
        guard let defaults else { return }
        KeychainHelper.delete(key: Self.tokenKey(for: machine))
        entries = entries.removing(machine: machine)
        defaults.set(entries.json, forKey: Self.defaultsKey)
    }
}

/// Where to attach and with what. Resolved per navigation from the store.
struct MirrorTarget: Hashable {
    let address: String
    let token: String
}

/// The address table, kept pure so its lookup and migration rules are testable without a Keychain.
struct MirrorConnectionEntries: Equatable {
    /// machine id → `host:port`. The empty key is a Mac that sent no machine id and matches any machine.
    private(set) var addresses: [String: String]

    init(addresses: [String: String] = [:]) { self.addresses = addresses }

    init(json: String?) {
        guard let json, let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { self.addresses = [:]; return }
        self.addresses = decoded
    }

    var json: String {
        let data = (try? JSONEncoder().encode(addresses)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    var isEmpty: Bool { addresses.isEmpty }

    /// Every stored Mac, the wildcard entry last, for Settings to list.
    var machines: [String] {
        addresses.keys.sorted { a, b in
            if a.isEmpty != b.isEmpty { return b.isEmpty }
            return a < b
        }
    }

    func address(for machine: String) -> String? { addresses[machine] }

    /// An exact machine wins over the wildcard from a Mac that sent no id.
    func match(for machine: String) -> (machine: String, address: String)? {
        if let exact = addresses[machine] { return (machine, exact) }
        if let wildcard = addresses[""] { return ("", wildcard) }
        return nil
    }

    func adding(machine: String, address: String) -> MirrorConnectionEntries {
        var copy = self
        copy.addresses[machine] = address
        return copy
    }

    func removing(machine: String) -> MirrorConnectionEntries {
        var copy = self
        copy.addresses[machine] = nil
        return copy
    }
}
