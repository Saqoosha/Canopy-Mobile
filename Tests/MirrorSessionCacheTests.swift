import Testing
@testable import CanopyMobile

struct MirrorSessionCacheTests {
    private let target = MirrorTarget(address: "mac:8770", token: "t")

    @Test func aPlainAttachIsCachedByAddressAndSession() {
        let key = MirrorLiveContent.cacheKey(target: target, sessionId: "s", open: nil, key: nil, cacheable: true)
        #expect(key == MirrorSessionCache.Key(address: "mac:8770", sessionId: "s"))
    }

    @Test func anAttachThatAsksTheMacToResumeIsNotCached() {
        #expect(MirrorLiveContent.cacheKey(target: target, sessionId: "s", open: .resume, key: nil, cacheable: true) == nil)
    }

    @Test func anAttachByTheMacsKeyIsNotCached() {
        #expect(MirrorLiveContent.cacheKey(target: target, sessionId: "s", open: nil, key: "k", cacheable: true) == nil)
    }

    @Test func aScreenThatDoesNotAskForTheCacheGetsNoKey() {
        #expect(MirrorLiveContent.cacheKey(target: target, sessionId: "s", open: nil, key: nil, cacheable: false) == nil)
    }
}
