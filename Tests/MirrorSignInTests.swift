import Foundation
import Testing
@testable import CanopyMobile

struct MirrorSignInTests {
    private let login: [String: Any] = ["type": "request", "requestId": "L1", "request": ["type": "login", "method": "claudeai"]]
    private let manualURL = "https://claude.com/cai/oauth/authorize?code=true&client_id=c"

    private func authURL(_ url: String, login id: String = "L1") -> [String: Any] {
        ["type": "from-extension",
         "message": ["type": "request", "channelId": "", "requestId": "R9",
                     "request": ["type": "auth_url", "url": url, "method": "claudeai", "loginRequestId": id]]]
    }

    @Test func aLoginSentHereOpensItsPage() {
        var signIn = MirrorSignIn()
        signIn.noteSent(login)
        #expect(signIn.pageToOpen(authURL(manualURL))?.absoluteString == manualURL)
    }

    @Test func aLoginStartedElsewhereOpensNothing() {
        var signIn = MirrorSignIn()
        signIn.noteSent(login)
        #expect(signIn.pageToOpen(authURL(manualURL, login: "OTHER")) == nil)
        var fresh = MirrorSignIn()
        #expect(fresh.pageToOpen(authURL(manualURL)) == nil)
    }

    @Test func theLoginsAnswerEndsIt() {
        var signIn = MirrorSignIn()
        signIn.noteSent(login)
        _ = signIn.pageToOpen(["type": "from-extension", "message": ["type": "response", "requestId": "L1"]])
        #expect(signIn.pageToOpen(authURL(manualURL)) == nil)
    }

    @Test func onlyAnHTTPSPageOpens() {
        var signIn = MirrorSignIn()
        signIn.noteSent(login)
        #expect(signIn.pageToOpen(authURL("http://claude.com/x")) == nil)
        #expect(signIn.pageToOpen(authURL("file:///etc/passwd")) == nil)
    }

    @Test func otherRequestsAreNotLogins() {
        var signIn = MirrorSignIn()
        signIn.noteSent(["type": "request", "requestId": "L1", "request": ["type": "submit_oauth_code", "code": "x"]])
        #expect(signIn.pageToOpen(authURL(manualURL)) == nil)
    }
}
