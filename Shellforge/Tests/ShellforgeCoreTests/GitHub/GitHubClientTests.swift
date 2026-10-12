// Ported from AiTerm (app/Tests/AiTermCoreTests/GitHubClientTests.swift), GPLv3, Laurens D'Hondt.
import Testing
import Foundation
@testable import ShellforgeCore
@testable import ShellforgeTestSupport

@Suite struct GitHubClientTests {
    let config = GitHubConfig(token: "ghp_tok")

    func pull(_ number: Int, title: String = "Add gift card", head: String = "feat-gift-card", author: String = "octocat",
              draft: Bool = false, headRepo: String? = "octocat/hello") -> [String: Any] {
        var headPart: [String: Any] = ["ref": head, "label": "\(headRepo?.split(separator: "/").first.map(String.init) ?? "ghost"):\(head)"]
        headPart["repo"] = headRepo.map { ["full_name": $0] as [String: Any] } ?? NSNull()
        return ["number": number, "title": title, "html_url": "https://github.com/octocat/hello/pull/\(number)",
                "draft": draft, "user": ["login": author], "head": headPart,
                "base": ["ref": "main", "repo": ["full_name": "octocat/hello"]]]
    }

    private func makeClient(_ handler: @escaping StubURLProtocol.Handler) -> (client: GitHubClient, stub: StubSession) {
        let stub = StubSession(handler: handler)
        return (GitHubClient(config: config, session: stub.session), stub)
    }

    @Test func theListIsOpenPullsNewestFirstWithTheToken() async throws {
        let body = try JSONSerialization.data(withJSONObject: [pull(87)])
        let (client, stub) = makeClient { _ in (200, body) }
        let found = try await client.pullRequests(repo: "octocat/hello", search: "")
        #expect(found == [MergeRequest(iid: 87, title: "Add gift card", sourceBranch: "feat-gift-card", targetBranch: "main",
                                       author: "octocat", state: "open", draft: false,
                                       url: "https://github.com/octocat/hello/pull/87")])
        let req = try #require(stub.lastRequest)
        #expect(req.url?.absoluteString == "https://api.github.com/repos/octocat/hello/pulls?state=open&sort=updated&direction=desc&per_page=100")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer ghp_tok")
        #expect(req.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(req.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
        #expect(found.first?.lane == "Open")
        #expect(found.first?.reference == "#87")
    }

    @Test func searchFiltersByTitleBranchOrAuthorAndKeepsTwentyFive() async throws {
        let many = (1...40).map { pull($0, title: "Change \($0)", head: "topic-\($0)", author: $0 == 3 ? "Sam" : "octocat") }
        let body = try JSONSerialization.data(withJSONObject: many + [pull(99, title: "Gift CARD flow")])
        let (client, _) = makeClient { _ in (200, body) }
        #expect(try await client.pullRequests(repo: "octocat/hello", search: "gift card").map(\.iid) == [99])
        #expect(try await client.pullRequests(repo: "octocat/hello", search: "topic-12").map(\.iid) == [12])
        #expect(try await client.pullRequests(repo: "octocat/hello", search: "sam").map(\.iid) == [3])
        #expect(try await client.pullRequests(repo: "octocat/hello", search: "").count == 25)
    }

    @Test func aNumberFetchesThatPullRequest() async throws {
        let body = try JSONSerialization.data(withJSONObject: pull(87))
        let (client, stub) = makeClient { _ in (200, body) }
        for text in ["87", "#87", "!87", " #87 "] {
            #expect(try await client.pullRequests(repo: "octocat/hello", search: text).map(\.iid) == [87], "\(text)")
        }
        #expect(stub.lastRequest?.url?.absoluteString == "https://api.github.com/repos/octocat/hello/pulls/87")
    }

    @Test func aPullRequestFetchedByNumberShowsItsRealState() async throws {
        for (state, merged, lane) in [("closed", true, "Merged"), ("closed", false, "Closed"), ("open", false, "Open")] {
            var payload = pull(88)
            payload["state"] = state
            payload["merged"] = merged
            let body = try JSONSerialization.data(withJSONObject: payload)
            let (client, _) = makeClient { _ in (200, body) }
            let found = try await client.pullRequests(repo: "octocat/hello", search: "#88")
            #expect(found.first?.lane == lane, "\(state) merged \(merged)")
        }
    }

    @Test func anUnknownNumberIsNothingFound() async throws {
        let (client, _) = makeClient { _ in (404, Data()) }
        #expect(try await client.pullRequests(repo: "octocat/hello", search: "#9999") == [])
    }

    @Test func aPullRequestFromAForkSaysWhichFork() async throws {
        let body = try JSONSerialization.data(withJSONObject: [pull(5, head: "patch-1", headRepo: "someone/hello")])
        let (client, _) = makeClient { _ in (200, body) }
        let found = try #require(try await client.pullRequests(repo: "octocat/hello", search: "").first)
        #expect(found.forkHead == "someone:patch-1")
        #expect(found.lane == "Fork")
    }

    /// Review focus 5: a fork deleted after its pull request was opened leaves `head.repo` null.
    @Test func aPullRequestFromADeletedForkIsStillListed() async throws {
        let body = try JSONSerialization.data(withJSONObject: [pull(6, head: "patch-2", headRepo: nil), pull(7)])
        let (client, _) = makeClient { _ in (200, body) }
        let found = try await client.pullRequests(repo: "octocat/hello", search: "")
        #expect(found.map(\.iid) == [6, 7])
        #expect(found.first?.forkHead == "ghost:patch-2")
        #expect(found.last?.forkHead == nil)
    }

    @Test func aMalformedEntryDropsOnlyItself() async throws {
        let body = try JSONSerialization.data(withJSONObject: [["number": "x"], pull(7)])
        let (client, _) = makeClient { _ in (200, body) }
        #expect(try await client.pullRequests(repo: "octocat/hello", search: "").map(\.iid) == [7])
    }

    @Test func statusCodesMapToErrors() async {
        for (status, error) in [(401, GitHubError.unauthorized), (403, .forbidden), (404, .repoNotFound("octocat/hello")), (500, .badResponse(500))] {
            await #expect(throws: error) { _ = try await self.makeClient { _ in (status, Data()) }.client.pullRequests(repo: "octocat/hello", search: "") }
        }
        await #expect(throws: GitHubError.decoding) {
            _ = try await self.makeClient { _ in (200, Data("<html>".utf8)) }.client.pullRequests(repo: "octocat/hello", search: "")
        }
    }

    @Test func eachErrorHasItsLine() {
        #expect(GitHubError.unauthorized.errorDescription == "Check your GitHub access token in Settings.")
        #expect(GitHubError.forbidden.errorDescription == "GitHub refused: the token can’t read this repository, or the rate limit was reached.")
        #expect(GitHubError.repoNotFound("octocat/hello").errorDescription == "GitHub has no repository at octocat/hello, or your token cannot see it.")
    }

    @Test func testConnectionReturnsTheLogin() async throws {
        let (client, stub) = makeClient { _ in (200, Data(#"{"login":"octocat"}"#.utf8)) }
        #expect(try await client.testConnection() == "octocat")
        #expect(stub.lastRequest?.url?.absoluteString == "https://api.github.com/user")
    }

    @Test func theTokenDoesNotFollowARedirectOffGitHubsAPI() async throws {
        let first = URL(string: "https://api.github.com/repos/octocat/hello/pulls?state=open&sort=updated&direction=desc&per_page=100")!
        let elsewhere = URL(string: "https://evil.example.com/pulls")!
        let stub = RedirectSession(redirects: [first: elsewhere], body: Data("[]".utf8))
        _ = try await GitHubClient(config: config, session: stub.session).pullRequests(repo: "octocat/hello", search: "")
        #expect(stub.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer ghp_tok", nil])
    }

    @Test func refsKnowTheirHost() {
        #expect(MergeRequestRef(iid: 87, title: "t", url: "https://github.com/octocat/hello/pull/87").reference == "#87")
        #expect(MergeRequestRef(iid: 4, title: "t", url: "https://git.example.net/web/acme-web/-/merge_requests/4").reference == "!4")
    }
}
