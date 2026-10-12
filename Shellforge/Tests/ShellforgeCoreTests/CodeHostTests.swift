// Ported from AiTerm (app/Tests/AiTermCoreTests/CodeHostTests.swift), GPLv3, Laurens D'Hondt.
import Testing
@testable import ShellforgeCore

@Suite struct CodeHostTests {
    @Test func aGitHubWebURLIsGitHubAndAnythingElseIsGitLab() {
        #expect(CodeHost(webURL: "https://github.com/octocat/hello/pull/87") == .gitHub)
        #expect(CodeHost(webURL: "https://GitHub.com/octocat/hello/pull/87") == .gitHub)
        #expect(CodeHost(webURL: "https://git.example.net/web/acme-web/-/merge_requests/4") == .gitLab)
        #expect(CodeHost(webURL: "not a url") == .gitLab)
    }

    @Test func eachHostWritesItsOwnReference() {
        #expect(CodeHost.gitHub.reference(87) == "#87")
        #expect(CodeHost.gitLab.reference(87) == "!87")
        #expect(CodeHost.gitHub.name == "GitHub")
        #expect(CodeHost.gitLab.name == "GitLab")
    }
}
