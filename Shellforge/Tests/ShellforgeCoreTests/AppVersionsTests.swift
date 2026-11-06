import Foundation
import Testing
@testable import ShellforgeCore

@Suite struct AppVersionsTests {
    @Test func readsTheBundleAndOSVersions() {
        let v = AppVersions(infoDictionary: ["CFBundleShortVersionString": "0.8.0", "CFBundleVersion": "123"],
                            os: OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0))
        #expect(v == AppVersions(version: "0.8.0", macOS: "26.1.0"))
    }

    @Test func missingBundleVersionIsAQuestionMark() {
        let v = AppVersions(infoDictionary: nil,
                            os: OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0))
        #expect(v.version == "?")
    }
}
