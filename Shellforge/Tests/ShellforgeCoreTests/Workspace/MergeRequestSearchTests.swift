// Ported from AiTerm (app/Tests/AiTermCoreTests/MergeRequestSearchTests.swift), GPLv3, Laurens D'Hondt.
import Foundation
import Testing
@testable import ShellforgeCore

/// Which host a project's merge requests are searched on, and with what — decided from the remote
/// and the connections, before anything is asked of either host.
struct MergeRequestSearchTests {
    let gitLab = GitLabConfig(hostURL: URL(string: "https://GitLab.example.net/")!, token: "t")
    let gitHub = GitHubConfig(token: "t")

    private func source(_ remote: String?, gitLab: GitLabConfig?, gitHub: GitHubConfig?) throws(MergeRequestSearch.Unavailable) -> any MergeRequestSearching {
        try MergeRequestSearch.source(for: ProviderDetector.detect(remoteUrl: remote, repoPath: "/nonexistent"), gitLab: gitLab, gitHub: gitHub)
    }

    @Test func aGitHubRemoteSearchesItsRepositoryOnGitHub() throws {
        let search = try #require(try source("git@github.com:octocat/hello.git", gitLab: gitLab, gitHub: gitHub) as? GitHubPullRequestSearch)
        #expect(search.repo == "octocat/hello")
        #expect(MergeRequestSearch.host(for: ProviderDetector.detect(remoteUrl: "git@github.com:octocat/hello.git")) == .gitHub)
    }

    @Test func aGitLabRemoteOnTheConfiguredHostSearchesItsProject() throws {
        let search = try #require(try source("git@gitlab.example.net:web/shop/acme.git", gitLab: gitLab, gitHub: gitHub) as? GitLabMergeRequestSearch)
        #expect(search.project == "web/shop/acme")
    }

    /// A self-hosted GitLab the detector can only call plain git is still GitLab's: only `.github`
    /// goes to GitHub.
    @Test func aPlainGitRemoteIsGitLabs() throws {
        let remote = ProviderDetector.detect(remoteUrl: "https://code.example.com/a/b.git", repoPath: "/nonexistent")
        #expect(remote.provider == .git)
        #expect(MergeRequestSearch.host(for: remote) == .gitLab)
        let selfHosted = GitLabConfig(hostURL: URL(string: "https://code.example.com")!, token: "t")
        let search = try #require(try source("https://code.example.com/a/b.git", gitLab: selfHosted, gitHub: gitHub) as? GitLabMergeRequestSearch)
        #expect(search.project == "a/b")
    }

    @Test func eachRefusalSaysWhy() {
        #expect(throws: MergeRequestSearch.Unavailable.notConnected(.gitHub)) {
            try source("git@github.com:octocat/hello.git", gitLab: gitLab, gitHub: nil)
        }
        #expect(throws: MergeRequestSearch.Unavailable.notConnected(.gitLab)) {
            try source("git@gitlab.example.net:web/acme.git", gitLab: nil, gitHub: gitHub)
        }
        #expect(throws: MergeRequestSearch.Unavailable.otherGitLabHost(remote: "gitlab.com", configured: "GitLab.example.net")) {
            try source("git@gitlab.com:web/acme.git", gitLab: gitLab, gitHub: gitHub)
        }
        #expect(throws: MergeRequestSearch.Unavailable.otherGitLabHost(remote: nil, configured: "GitLab.example.net")) {
            try source(nil, gitLab: gitLab, gitHub: gitHub)
        }
        #expect(throws: MergeRequestSearch.Unavailable.noRepositoryPath(.gitHub)) {
            try MergeRequestSearch.source(for: RemoteInfo(host: "github.com", path: "", provider: .github), gitLab: nil, gitHub: gitHub)
        }
        #expect(throws: MergeRequestSearch.Unavailable.noRepositoryPath(.gitLab)) {
            try MergeRequestSearch.source(for: RemoteInfo(host: "gitlab.example.net", path: "", provider: .gitlab), gitLab: gitLab, gitHub: nil)
        }
    }
}
