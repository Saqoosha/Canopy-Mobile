import Foundation
import Testing
@testable import CanopyMobile

/// What the tap handler needs before it can route, and what it says when it
/// does not have it.
///
/// `userNotificationCenter(_:didReceive:)` takes a `UNNotificationResponse`,
/// which cannot be constructed outside the system — so the condition is on a
/// static function instead, and this is what pins it.
struct TapRoutingTests {
    @Test("A complete payload is missing nothing")
    func completePayload() {
        let info: [AnyHashable: Any] = ["machine": "m1", "sessionId": "s1", "kind": "asking"]
        #expect(PushRegistrar.missingTapKeys(in: info).isEmpty)
    }

    @Test("Each missing key is named")
    func namesWhatIsMissing() {
        #expect(PushRegistrar.missingTapKeys(in: ["sessionId": "s1"]) == ["machine"])
        #expect(PushRegistrar.missingTapKeys(in: ["machine": "m1"]) == ["sessionId"])
        #expect(PushRegistrar.missingTapKeys(in: [:]) == ["machine", "sessionId"])
    }

    // The routing `if let` is `as? String`, so a key of the wrong type drops
    // the tap exactly as an absent one does. The log has to say so.
    @Test("A key of the wrong type counts as missing")
    func wrongTypeIsMissing() {
        let info: [AnyHashable: Any] = ["machine": 42, "sessionId": "s1"]
        #expect(PushRegistrar.missingTapKeys(in: info) == ["machine"])
    }

    // `resumeId` and `requestId` are forwarded when present and not required.
    // Demanding them would drop taps the app can route perfectly well.
    @Test("The optional ids are not required to route")
    func optionalIdsAreNotRequired() {
        let info: [AnyHashable: Any] = ["machine": "m1", "sessionId": "s1"]
        #expect(PushRegistrar.missingTapKeys(in: info).isEmpty)
    }
}
