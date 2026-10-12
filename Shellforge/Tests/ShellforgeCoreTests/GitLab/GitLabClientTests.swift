// Ported from AiTerm (app/Tests/AiTermCoreTests/GitLabClientTests.swift), GPLv3, Laurens D'Hondt.
import Testing
import Foundation
@testable import ShellforgeCore
@testable import ShellforgeTestSupport

@Suite struct GitLabClientTests {
    let config = GitLabConfig(hostURL: URL(string: "https://git.example.net")!, token: "tok")
    let mr: [String: Any] = ["iid": 4, "title": "Add gift card", "source_branch": "feat-gift-card",
                             "target_branch": "main", "state": "opened", "draft": false,
                             "author": ["name": "Sam Rivera"],
                             "web_url": "https://git.example.net/web/acme-web/-/merge_requests/4"]

    private func makeClient(_ handler: @escaping StubURLProtocol.Handler) -> (client: GitLabClient, stub: StubSession) {
        let stub = StubSession(handler: handler)
        return (GitLabClient(config: config, session: stub.session), stub)
    }

    @Test func testDefaultListParsesAndAuthenticates() async throws {
        let body = try JSONSerialization.data(withJSONObject: [mr])
        let (client, stub) = makeClient { _ in (200, body) }
        let found = try await client.mergeRequests(project: "web/acme-web", search: "")
        #expect(found == [MergeRequest(iid: 4, title: "Add gift card", sourceBranch: "feat-gift-card",
                                       targetBranch: "main", author: "Sam Rivera", state: "opened", draft: false,
                                       url: "https://git.example.net/web/acme-web/-/merge_requests/4")])
        let req = stub.lastRequest!
        #expect(req.value(forHTTPHeaderField: "PRIVATE-TOKEN") == "tok")
        // absoluteString, not `.path`: `URL.path` decodes %2F back to a slash and would pass
        // even if the project segment were wrongly split into three path components.
        #expect(req.url?.absoluteString == "https://git.example.net/api/v4/projects/web%2Facme-web/merge_requests?state=opened&order_by=updated_at&per_page=25")
    }

    @Test func testSubgroupPathIsEncodedAsOneSegment() {
        #expect(GitLabClient.encodedProject("a/b/c") == "a%2Fb%2Fc")
        #expect(GitLabClient.encodedProject("group/my project") == "group%2Fmy%20project")
    }

    @Test func testSearchAddsQueryAndFields() async throws {
        let (client, stub) = makeClient { _ in (200, Data("[]".utf8)) }
        _ = try await client.mergeRequests(project: "web/acme-web", search: "gift")
        let url = stub.lastRequest!.url!.absoluteString
        #expect(url.contains("search=gift"))
        #expect(url.contains("in=title,description") || url.contains("in=title%2Cdescription"))
        #expect(url.contains("state=opened"))
    }

    @Test func testNumberQueryFetchesThatMergeRequestDirectly() async throws {
        let body = try JSONSerialization.data(withJSONObject: mr)
        let (client, stub) = makeClient { _ in (200, body) }
        for query in ["!4", "4", "  !4 "] {
            let found = try await client.mergeRequests(project: "web/acme-web", search: query)
            #expect(found.map(\.iid) == [4])
            #expect(stub.lastRequest!.url!.absoluteString.hasSuffix("/merge_requests/4"))
        }
    }

    @Test func testUnauthorizedAndNotFoundMapToErrors() async {
        await #expect(throws: GitLabError.unauthorized) {
            _ = try await makeClient { _ in (401, Data()) }.client.mergeRequests(project: "p", search: "")
        }
        await #expect(throws: GitLabError.unauthorized) {
            _ = try await makeClient { _ in (403, Data()) }.client.mergeRequests(project: "p", search: "")
        }
        await #expect(throws: GitLabError.projectNotFound("p")) {
            _ = try await makeClient { _ in (404, Data()) }.client.mergeRequests(project: "p", search: "")
        }
        await #expect(throws: GitLabError.badResponse(500)) {
            _ = try await makeClient { _ in (500, Data()) }.client.mergeRequests(project: "p", search: "")
        }
    }

    /// GitLab answers 404 for a merge request number that does not exist: nothing found, not a
    /// missing project.
    @Test func anUnknownMergeRequestNumberFindsNothing() async throws {
        let (client, _) = makeClient { _ in (404, Data(#"{"message":"404 Not found"}"#.utf8)) }
        #expect(try await client.mergeRequests(project: "p", search: "!99").isEmpty)
    }

    /// The connection test asks for no project; a 404 there is a host that serves no GitLab API.
    @Test func aConnectionTestThatFindsNoAPIPointsAtTheHost() async {
        await #expect(throws: GitLabError.noAPI("https://git.example.net")) {
            _ = try await makeClient { _ in (404, Data()) }.client.testConnection()
        }
        let slashed = StubSession { _ in (404, Data()) }
        await #expect(throws: GitLabError.noAPI("https://git.example.net")) {
            _ = try await GitLabClient(config: GitLabConfig(hostURL: URL(string: "https://git.example.net//")!, token: "tok"),
                                       session: slashed.session).testConnection()
        }
        #expect(GitLabError.noAPI("https://git.example.net").errorDescription
                == "GitLab’s API was not found at https://git.example.net. Check the host URL in Settings.")
    }

    @Test func testMalformedBodyIsADecodingError() async {
        await #expect(throws: GitLabError.decoding) {
            _ = try await makeClient { _ in (200, Data("not json".utf8)) }.client.mergeRequests(project: "p", search: "")
        }
    }

    @Test func aMalformedEntryDropsOnlyItself() async throws {
        let body = try JSONSerialization.data(withJSONObject: [["iid": "four"], mr])
        let (client, _) = makeClient { _ in (200, body) }
        #expect(try await client.mergeRequests(project: "p", search: "").map(\.iid) == [4])
    }

    @Test func tokenDoesNotFollowARedirectToAnotherHost() async throws {
        let user = URL(string: "https://git.example.net/api/v4/user")!
        let elsewhere = URL(string: "https://elsewhere.example.com/user")!
        let stub = RedirectSession(redirects: [user: elsewhere], body: Data(#"{"username":"sam.rivera"}"#.utf8))
        #expect(try await GitLabClient(config: config, session: stub.session).testConnection() == "sam.rivera")
        #expect(stub.requests.map(\.url) == [user, elsewhere])
        #expect(stub.requests.map { $0.value(forHTTPHeaderField: "PRIVATE-TOKEN") } == ["tok", nil])
    }

    @Test func aCancelledRequestThrowsCancellation() async {
        let (client, _) = makeClient { _ in (200, Data("[]".utf8)) }
        let search = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.mergeRequests(project: "p", search: "")
        }
        await #expect(throws: CancellationError.self) { _ = try await search.value }
    }

    @Test func testConnectionReturnsTheUsername() async throws {
        let (client, stub) = makeClient { _ in (200, try! JSONSerialization.data(withJSONObject: ["username": "sam.rivera"])) }
        #expect(try await client.testConnection() == "sam.rivera")
        #expect(stub.lastRequest!.url!.absoluteString == "https://git.example.net/api/v4/user")
    }
}
