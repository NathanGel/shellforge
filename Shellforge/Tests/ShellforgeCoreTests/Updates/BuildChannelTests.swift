import Foundation
import Testing
@testable import ShellforgeCore

/// A Development build carries `ShellforgeDevBuild = YES`, from the `SHELLFORGE_DEV_BUILD` build
/// setting that only that configuration sets; every other build expands it to nothing.
@Suite struct BuildChannelTests {
    @Test func theDevelopmentConfigurationsMarkIsADevBuild() {
        #expect(BuildChannel(infoDictionary: ["ShellforgeDevBuild": "YES"]) == .dev)
        #expect(BuildChannel(infoDictionary: ["ShellforgeDevBuild": true]) == .dev)
        #expect(BuildChannel(infoDictionary: ["ShellforgeDevBuild": "1"]) == .dev)
    }

    @Test func anEmptyOrMissingMarkIsARelease() {
        #expect(BuildChannel(infoDictionary: ["ShellforgeDevBuild": ""]) == .release)
        #expect(BuildChannel(infoDictionary: ["ShellforgeDevBuild": "NO"]) == .release)
        #expect(BuildChannel(infoDictionary: ["ShellforgeDevBuild": false]) == .release)
        #expect(BuildChannel(infoDictionary: [:]) == .release)
        #expect(BuildChannel(infoDictionary: nil) == .release)
    }

    /// AiTerm's own key means nothing here.
    @Test func aiTermsKeyIsNotShellforges() {
        #expect(BuildChannel.infoKey == "ShellforgeDevBuild")
        #expect(BuildChannel(infoDictionary: ["AiTermDevBuild": true]) == .release)
    }
}
