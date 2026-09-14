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
    /// The single-Mac keys from before the table, removed once their address has been migrated.
    static let legacyAddressKey = "mirrorAddress"
    static let legacyMachineKey = "mirrorMachine"
    static let legacyTokenKey = "mirrorToken"

    private(set) var entries: MirrorConnectionEntries
    /// nil is the demo store: starts empty, never touches UserDefaults or the Keychain.
    private let defaults: UserDefaults?
    /// Passwords already read, so a render pass costs a dictionary lookup rather than a Keychain query.
    @ObservationIgnored private var tokens: [String: String] = [:]

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        guard let defaults else { entries = MirrorConnectionEntries(); return }
        let stored = MirrorConnectionEntries(json: defaults.string(forKey: Self.defaultsKey))
        let plan = MirrorConnectionEntries.legacyMigration(
            address: defaults.string(forKey: Self.legacyAddressKey),
            machine: defaults.string(forKey: Self.legacyMachineKey),
            into: stored)
        entries = stored
        guard let plan else {
            defaults.removeObject(forKey: Self.legacyAddressKey)
            defaults.removeObject(forKey: Self.legacyMachineKey)
            return
        }
        // The password moves first; if that write fails nothing else is touched, so the next launch retries.
        if let token = KeychainHelper.load(key: Self.legacyTokenKey) {
            guard KeychainHelper.upsert(key: Self.tokenKey(for: plan.machine), value: token) == errSecSuccess else { return }
            KeychainHelper.delete(key: Self.legacyTokenKey)
        }
        entries = plan.entries
        defaults.set(entries.json, forKey: Self.defaultsKey)
        defaults.removeObject(forKey: Self.legacyAddressKey)
        defaults.removeObject(forKey: Self.legacyMachineKey)
    }

    static func tokenKey(for machine: String) -> String { "mirrorToken.\(machine)" }

    var isEmpty: Bool { entries.isEmpty }

    /// The address and password to attach to `machine`'s sessions with; nil when no paste covers it or its password is not in the Keychain.
    func target(for machine: String) -> MirrorTarget? {
        guard defaults != nil, let match = entries.match(for: machine), let token = token(for: match.machine) else { return nil }
        return MirrorTarget(address: match.address, token: token)
    }

    private func token(for machine: String) -> String? {
        if let cached = tokens[machine] { return cached }
        guard let token = KeychainHelper.load(key: Self.tokenKey(for: machine)), !token.isEmpty else { return nil }
        tokens[machine] = token
        return token
    }

    func save(_ info: MirrorConnectionInfo) -> OSStatus {
        guard let defaults else { return errSecSuccess }
        let status = KeychainHelper.upsert(key: Self.tokenKey(for: info.machine), value: info.token)
        guard status == errSecSuccess else { return status }
        tokens[info.machine] = info.token
        entries = entries.adding(machine: info.machine, address: info.address)
        defaults.set(entries.json, forKey: Self.defaultsKey)
        return status
    }

    func forget(machine: String) {
        guard let defaults else { return }
        KeychainHelper.delete(key: Self.tokenKey(for: machine))
        tokens[machine] = nil
        entries = entries.removing(machine: machine)
        defaults.set(entries.json, forKey: Self.defaultsKey)
    }
}

/// Where to attach and with what.
struct MirrorTarget: Hashable {
    let address: String
    let token: String
}

/// The address table, kept pure so its lookup, ordering and migration rules are testable without a Keychain.
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

    /// What the pre-table single-Mac keys become: the machine to file the password under and the table after adding it. nil when there is nothing to migrate.
    static func legacyMigration(address: String?, machine: String?, into existing: MirrorConnectionEntries) -> (machine: String, entries: MirrorConnectionEntries)? {
        guard let address, !address.isEmpty else { return nil }
        let machine = machine ?? ""
        return (machine, existing.adding(machine: machine, address: address))
    }
}
