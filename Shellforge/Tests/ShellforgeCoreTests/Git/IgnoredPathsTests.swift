import Foundation
import Testing
@testable import ShellforgeTestSupport
@testable import ShellforgeCore

/// What a repository ignores, as the panels' watchers drop changes by it.
@Suite struct IgnoredPathsTests {
    @Test func aChangeUnderAnIgnoredFolderIsCovered() {
        let rules = IgnoredPaths(["build", "node_modules", "packages/web/dist", ".DS_Store"])
        #expect(rules.covers("build"))
        #expect(rules.covers("build/out/app.o"))
        #expect(rules.covers("packages/web/dist/main.js"))
        #expect(rules.covers(".DS_Store"))
        #expect(!rules.covers("builder/app.ts"), "a name that only starts like one")
        #expect(!rules.covers("packages/web/src/main.ts"))
        #expect(!rules.covers(""), "the folder itself")
        #expect(!rules.covers(".git/index"))
    }

    @Test func aBatchCountsUnlessEveryChangeIsIgnored() {
        let rules = IgnoredPaths(["build"])
        #expect(rules.relevant(["build/a.o", "build/b.o"]) == nil)
        #expect(rules.relevant(["build/a.o", "src/app.ts"]) == ["src/app.ts"])
        #expect(rules.relevant([]) == [], "a batch that says nothing still counts")
        #expect(IgnoredPaths.none.relevant(["build/a.o"]) == ["build/a.o"])
    }

    @Test func ignoreRulesAreTold() {
        #expect(IgnoredPaths.changesRules(".gitignore"))
        #expect(IgnoredPaths.changesRules("packages/web/.gitignore"))
        #expect(IgnoredPaths.changesRules(".git/info/exclude"))
        #expect(!IgnoredPaths.changesRules("docs/gitignore.md"))
        #expect(!IgnoredPaths.changesRules("src/app.gitignore"))
    }

    /// git names an ignored folder once, with `--directory`, and ignored files one by one; what is
    /// tracked or untracked and not ignored is not listed.
    @Test func gitListsTheIgnoredFoldersAndFiles() throws {
        let repo = try GitRepoFixture()
        try "build/\n*.log\n".write(toFile: repo.path + "/.gitignore", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: repo.path + "/build/out", withIntermediateDirectories: true)
        try "x\n".write(toFile: repo.path + "/build/out/app.o", atomically: true, encoding: .utf8)
        try "x\n".write(toFile: repo.path + "/debug.log", atomically: true, encoding: .utf8)
        try "x\n".write(toFile: repo.path + "/notes.md", atomically: true, encoding: .utf8)
        let rules = IgnoredPaths.read(repo.path, launcher: repo.launcher)
        #expect(rules.entries == ["build", "debug.log"])
    }

    /// The read is an automatic one: a repository's fsmonitor runs nothing.
    @Test func theReadRunsNoFsmonitor() throws {
        let repo = try GitRepoFixture()
        let marker = (repo.path as NSString).deletingLastPathComponent + "/fsmonitor-ran"
        let script = (repo.path as NSString).deletingLastPathComponent + "/fsmonitor.sh"
        try "#!/bin/sh\ntouch '\(marker)'\nexit 1\n".write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        try repo.git("config", "core.fsmonitor", script)
        _ = IgnoredPaths.read(repo.path, launcher: repo.launcher)
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test func aFolderThatIsNotARepositoryIgnoresNothing() throws {
        let folder = TestScratch.root.appendingPathComponent("shellforge-ignored-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let launcher = CommandLauncher { ResolvedEnvironment(variables: ["PATH": "/usr/bin:/bin", "GIT_CEILING_DIRECTORIES": TestScratch.root.path],
                                                             source: .loginShell("/bin/sh")) }
        #expect(IgnoredPaths.read(folder, launcher: launcher) == .none)
    }
}
