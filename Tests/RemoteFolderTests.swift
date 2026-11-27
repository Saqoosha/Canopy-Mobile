import Foundation
import Testing
@testable import CanopyMobile

struct RemoteFolderTests {
    @Test func joinUnderRoot() {
        #expect(RemoteFolder.join(base: "/", name: "Projects") == "/Projects")
    }

    @Test func joinNested() {
        #expect(RemoteFolder.join(base: "/Users/me", name: "app") == "/Users/me/app")
    }

    @Test func parentWalksUpToRoot() {
        #expect(RemoteFolder.parent(of: "/Users/me/repos/Work") == "/Users/me/repos")
        #expect(RemoteFolder.parent(of: "/Users/me/") == "/Users")
        #expect(RemoteFolder.parent(of: "/Users") == "/")
        #expect(RemoteFolder.parent(of: "/") == nil)
        #expect(RemoteFolder.parent(of: "/private/var/x") == "/private/var")
    }

    @Test func displayNameKeepsRoot() {
        #expect(RemoteFolder.displayName(of: "/Users/me") == "me")
        #expect(RemoteFolder.displayName(of: "/") == "/")
    }

    @Test func noFolderPathMatchesCanopy() {
        #expect(RemoteFolder.noFolderPath(home: "/Users/me") == "/Users/me/Library/Application Support/Canopy/no-folder")
        #expect(RemoteFolder.noFolderPath(home: nil) == nil)
        #expect(RemoteFolder.noFolderPath(home: "relative") == nil)
    }

    @Test func validateRejectsEmptyAndSeparators() {
        #expect(RemoteFolder.validateName("") != nil)
        #expect(RemoteFolder.validateName("   ") != nil)
        #expect(RemoteFolder.validateName("a/b") != nil)
        #expect(RemoteFolder.validateName(".") != nil)
        #expect(RemoteFolder.validateName("..") != nil)
    }

    @Test func validateAcceptsSimpleName() {
        #expect(RemoteFolder.validateName("my-app") == nil)
        #expect(RemoteFolder.validateName("  trimmed  ") == nil)
    }

    @Test func createdPathFromResult() {
        #expect(RemoteFolder.createdPath(from: ["path": "/tmp/x"]) == "/tmp/x")
        #expect(RemoteFolder.createdPath(from: [:]) == nil)
        #expect(RemoteFolder.createdPath(from: ["path": ""]) == nil)
    }

    @Test func createErrorMapsCommonFailures() {
        #expect(RemoteFolder.createErrorMessage(MachineControl.ControlError.failed("already exists")).contains("already exists"))
        #expect(RemoteFolder.createErrorMessage(MachineControl.ControlError.failed("permission denied")).contains("can't create"))
        #expect(RemoteFolder.createErrorMessage(MachineControl.ControlError.failed("unknown verb")).contains("Update Canopy"))
        #expect(RemoteFolder.createErrorMessage(MachineControl.ControlError.closed).contains("Lost connection"))
    }
}
