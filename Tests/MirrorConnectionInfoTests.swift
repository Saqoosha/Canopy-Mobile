import Foundation
import Testing
@testable import CanopyMobile

struct MirrorConnectionInfoTests {
    @Test func parsesTheStringCanopyCopies() {
        let info = MirrorConnectionInfo.parse("canopy-mirror://100.116.127.93:8770?token=Ab_-9z&machine=C211-MBP")
        #expect(info == MirrorConnectionInfo(host: "100.116.127.93", port: 8770, token: "Ab_-9z", machine: "C211-MBP"))
        #expect(info?.address == "100.116.127.93:8770")
    }

    @Test func acceptsAnOlderMacWithoutAMachineId() {
        #expect(MirrorConnectionInfo.parse("canopy-mirror://100.64.0.1:8770?token=t")?.machine == "")
    }

    @Test func toleratesWhitespaceFromAPaste() {
        #expect(MirrorConnectionInfo.parse("  canopy-mirror://100.64.0.1:9000?token=t\n")?.port == 9000)
    }

    @Test func rejectsAStringWithoutAPassword() {
        #expect(MirrorConnectionInfo.parse("canopy-mirror://100.64.0.1:8770") == nil)
        #expect(MirrorConnectionInfo.parse("canopy-mirror://100.64.0.1:8770?token=") == nil)
    }

    @Test func rejectsAMissingOrZeroPort() {
        #expect(MirrorConnectionInfo.parse("canopy-mirror://100.64.0.1?token=t") == nil)
        #expect(MirrorConnectionInfo.parse("canopy-mirror://100.64.0.1:0?token=t") == nil)
    }

    @Test func rejectsOtherSchemes() {
        #expect(MirrorConnectionInfo.parse("https://100.64.0.1:8770?token=t") == nil)
        #expect(MirrorConnectionInfo.parse("100.64.0.1:8770") == nil)
    }
}
