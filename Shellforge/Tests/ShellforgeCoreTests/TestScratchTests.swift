import Foundation
import Testing
@testable import ShellforgeTestSupport

/// Tests leave nothing behind: every scratch folder is under one root for the run, removed when
/// the test process exits.
@Suite struct TestScratchTests {
    @Test func aScratchFolderLivesUnderTheRunsRoot() {
        let root = TestScratch.root
        #expect(root.lastPathComponent == "shellforge-tests-\(getpid())")
        #expect(FileManager.default.fileExists(atPath: root.path))
        #expect(TestScratch.root.appendingPathComponent("x").path.hasPrefix(root.path))
    }
}
