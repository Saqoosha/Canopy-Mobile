import Foundation
import Testing
@testable import CanopyMobile

struct MirrorConnectionEntriesTests {
    @Test func anExactMachineWinsOverTheWildcard() {
        let entries = MirrorConnectionEntries(addresses: ["": "100.64.0.1:8770", "MBP": "100.64.0.2:8770"])
        #expect(entries.match(for: "MBP")?.address == "100.64.0.2:8770")
        #expect(entries.match(for: "MBP")?.machine == "MBP")
    }

    @Test func aMacWithoutAnIdMatchesAnyMachine() {
        let entries = MirrorConnectionEntries(addresses: ["": "100.64.0.1:8770"])
        #expect(entries.match(for: "Studio")?.address == "100.64.0.1:8770")
        #expect(entries.match(for: "Studio")?.machine == "")
    }

    @Test func anUnknownMachineHasNoMatch() {
        let entries = MirrorConnectionEntries(addresses: ["MBP": "100.64.0.2:8770"])
        #expect(entries.match(for: "Studio") == nil)
    }

    @Test func roundTripsThroughJSON() {
        let entries = MirrorConnectionEntries(addresses: ["MBP": "100.64.0.2:8770", "Studio": "100.64.0.3:8770"])
        #expect(MirrorConnectionEntries(json: entries.json) == entries)
    }

    @Test func aMissingOrBrokenTableIsEmpty() {
        #expect(MirrorConnectionEntries(json: nil).isEmpty)
        #expect(MirrorConnectionEntries(json: "not json").isEmpty)
        #expect(MirrorConnectionEntries(json: "[1,2]").isEmpty)
    }

    @Test func addingReplacesTheSameMacAndRemovingLeavesTheOthers() {
        let entries = MirrorConnectionEntries(addresses: ["MBP": "100.64.0.2:8770"])
            .adding(machine: "MBP", address: "100.64.0.9:9000")
            .adding(machine: "Studio", address: "100.64.0.3:8770")
        #expect(entries.address(for: "MBP") == "100.64.0.9:9000")
        #expect(entries.removing(machine: "MBP").addresses == ["Studio": "100.64.0.3:8770"])
    }

    @Test func migratesTheOldSingleMacUnderItsMachineId() {
        let plan = MirrorConnectionEntries.legacyMigration(address: "100.64.0.2:8770", machine: "MBP", into: MirrorConnectionEntries())
        #expect(plan?.machine == "MBP")
        #expect(plan?.entries.address(for: "MBP") == "100.64.0.2:8770")
    }

    @Test func anOldMacWithoutAMachineIdMigratesToTheWildcard() {
        let plan = MirrorConnectionEntries.legacyMigration(address: "100.64.0.1:8770", machine: nil, into: MirrorConnectionEntries())
        #expect(plan?.machine == "")
        #expect(plan?.entries.match(for: "anything")?.address == "100.64.0.1:8770")
    }

    @Test func nothingToMigrateIsNil() {
        let existing = MirrorConnectionEntries(addresses: ["Studio": "100.64.0.3:8770"])
        #expect(MirrorConnectionEntries.legacyMigration(address: nil, machine: "MBP", into: existing) == nil)
        #expect(MirrorConnectionEntries.legacyMigration(address: "", machine: "MBP", into: existing) == nil)
    }

    @Test func migrationKeepsTheMacsAlreadyInTheTable() {
        let existing = MirrorConnectionEntries(addresses: ["Studio": "100.64.0.3:8770"])
        let plan = MirrorConnectionEntries.legacyMigration(address: "100.64.0.2:8770", machine: "MBP", into: existing)
        #expect(plan?.entries.machines == ["MBP", "Studio"])
    }

    @Test func listsNamedMacsFirstAndTheWildcardLast() {
        let entries = MirrorConnectionEntries(addresses: ["": "a", "Studio": "b", "MBP": "c"])
        #expect(entries.machines == ["MBP", "Studio", ""])
    }
}
