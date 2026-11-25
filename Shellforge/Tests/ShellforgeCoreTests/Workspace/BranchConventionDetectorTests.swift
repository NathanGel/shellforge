import Foundation
import Testing
@testable import ShellforgeCore

/// A repository's branch naming, read from what it says or what it does.
@Suite struct BranchConventionDetectorTests {
    @Test func anExampleBranchMapsToAPattern() {
        #expect(BranchConventionDetector.pattern(ofExample: "ABC-123") == "{KEY}")
        #expect(BranchConventionDetector.pattern(ofExample: "ABC-123-add-login") == "{KEY}-{slug}")
        #expect(BranchConventionDetector.pattern(ofExample: "abc-123-add-login") == "{key}-{slug}")
        #expect(BranchConventionDetector.pattern(ofExample: "feat/abc-123-add-login") == BranchPattern.typeAndName)
        #expect(BranchConventionDetector.pattern(ofExample: "fix/add-login") == BranchPattern.typeAndName)
        #expect(BranchConventionDetector.pattern(ofExample: "feature/ABC-123") == "feature/{KEY}")
        #expect(BranchConventionDetector.pattern(ofExample: "fix/ABC-123-add-login") == "{type}/{KEY}-{slug}")
        #expect(BranchConventionDetector.pattern(ofExample: "main") == nil)
        #expect(BranchConventionDetector.pattern(ofExample: "add-login") == nil)
        #expect(BranchConventionDetector.pattern(ofExample: "Release 1.0") == nil)
    }

    /// A line about branches, with a backticked example.
    @Test func theDocsSayHowBranchesAreNamed() {
        let doc = """
        # Agents
        Run `make test` before committing.
        Branches are named for the bare ticket key (`ABC-1234`), nothing else.
        """
        #expect(BranchConventionDetector.fromDocs(doc) == "{KEY}")
        #expect(BranchConventionDetector.fromDocs("Run `ABC-1` first.") == nil, "not a line about branches")
        #expect(BranchConventionDetector.fromDocs("Branch from `main`, then `ABC-1-short-name`.") == "{KEY}-{slug}")
    }

    /// At least five branches of one shape, and most of them.
    @Test func theBranchesShowAClearMajority() {
        let keys = ["ABC-1", "ABC-2", "ABC-3", "ABC-4", "ABC-5"]
        #expect(BranchConventionDetector.fromBranches(keys + ["main", "develop", "feat/x"]) == "{KEY}")
        #expect(BranchConventionDetector.fromBranches(Array(keys.prefix(4))) == nil, "too few")
        #expect(BranchConventionDetector.fromBranches(keys + ["feat/a", "feat/b", "fix/c", "fix/d"]) == nil, "no clear majority")
        #expect(BranchConventionDetector.fromBranches([]) == nil)
        // Most working branches follow no shape at all: five keys among twenty are no convention.
        #expect(BranchConventionDetector.fromBranches(keys + (1...20).map { "feature/work\($0)" }) == nil)
    }

    /// The docs win over the branches, and say where the suggestion came from.
    @Test func detectionNamesItsSource() throws {
        let repo = try GitRepoFixture()
        for n in 1...5 { _ = try repo.git("branch", "ABC-\(n)-work") }
        #expect(BranchConventionDetector.detect(in: repo.path, launcher: repo.launcher)
                == BranchConvention(pattern: "{KEY}-{slug}", source: "existing branches"))
        try "Name branches like `ABC-123`.\n".write(toFile: repo.path + "/AGENTS.md", atomically: true, encoding: .utf8)
        #expect(BranchConventionDetector.detect(in: repo.path, launcher: repo.launcher)
                == BranchConvention(pattern: "{KEY}", source: "AGENTS.md"))
    }
}
