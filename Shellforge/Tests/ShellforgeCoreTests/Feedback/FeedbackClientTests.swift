import Foundation
import Testing
@testable import ShellforgeTestSupport
@testable import ShellforgeCore

@Suite struct FeedbackClientTests {
    let endpoint = URL(string: "https://relay.example/feedback")!
    let versions = AppVersions(version: "0.8.0", macOS: "26.1.0")
    var submission: FeedbackSubmission { FeedbackSubmission(versions: versions, good: "fast", bad: "crashes", rating: 4) }

    private func failure(status: Int, body: String) async -> FeedbackFailure? {
        let stub = StubSession { _ in (status, Data(body.utf8)) }
        let client = FeedbackClient(endpoint: endpoint, session: stub.session)!
        do { _ = try await client.send(submission); return nil }
        catch { return error as? FeedbackFailure }
    }

    @Test func postsJSON() async throws {
        let stub = StubSession { _ in (201, Data(#"{"number":7}"#.utf8)) }
        _ = try await FeedbackClient(endpoint: endpoint, session: stub.session)!.send(submission)
        let request = try #require(stub.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.timeoutInterval == 15)
        let body = try #require(request.httpBody)
        #expect(try JSONDecoder().decode(FeedbackSubmission.self, from: body) == submission)
    }

    @Test func aBareWorkerURLPostsToSlashFeedback() async throws {
        for bare in ["https://relay.example", "https://relay.example/"] {
            let stub = StubSession { _ in (201, Data(#"{"number":7}"#.utf8)) }
            _ = try await FeedbackClient(endpoint: URL(string: bare)!, session: stub.session)!.send(submission)
            let url = try #require(stub.lastRequest?.url)
            #expect(url.absoluteString == "https://relay.example/feedback", "\(bare)")
        }
    }

    @Test func anEndpointWithAPathIsPostedToAsGiven() async throws {
        let stub = StubSession { _ in (201, Data(#"{"number":7}"#.utf8)) }
        _ = try await FeedbackClient(endpoint: endpoint, session: stub.session)!.send(submission)
        #expect(stub.lastRequest?.url?.absoluteString == "https://relay.example/feedback")
        let other = StubSession { _ in (201, Data(#"{"number":7}"#.utf8)) }
        _ = try await FeedbackClient(endpoint: URL(string: "https://relay.example/v2/feedback")!, session: other.session)!.send(submission)
        #expect(other.lastRequest?.url?.path == "/v2/feedback")
    }

    @Test func returnsTheNumber() async throws {
        let stub = StubSession { _ in (201, Data(#"{"number":7,"url":"https://evil.example"}"#.utf8)) }
        #expect(try await FeedbackClient(endpoint: endpoint, session: stub.session)!.send(submission) == 7)
    }

    @Test func statusMapping() async {
        #expect(await failure(status: 429, body: #"{"error":"daily"}"#) == .daily)
        #expect(await failure(status: 429, body: #"{"error":"rate"}"#) == .tooMany)
        #expect(await failure(status: 429, body: #"{"error":"busy"}"#) == .tooMany)
        #expect(await failure(status: 429, body: "nonsense") == .tooMany)
        #expect(await failure(status: 503, body: #"{"error":"off"}"#) == .off)
        #expect(await failure(status: 400, body: #"{"error":"secret"}"#) == .secret)
        #expect(await failure(status: 400, body: #"{"error":"fields"}"#) == .tooLong)
        #expect(await failure(status: 400, body: #"{"error":"size"}"#) == .tooLong)
        #expect(await failure(status: 400, body: #"{"error":"json"}"#) == .other)
        #expect(await failure(status: 502, body: #"{"error":"github"}"#) == .other)
        #expect(await failure(status: 405, body: #"{"error":"method"}"#) == .other)
        #expect(await failure(status: 201, body: "{}") == .other)
        #expect(await failure(status: 201, body: "not json") == .other)
    }

    @Test func refusedConnectionIsOther() async {
        let client = FeedbackClient(endpoint: endpoint, session: RefusedURLProtocol.session)!
        do { _ = try await client.send(submission); Issue.record("should have thrown") }
        catch { #expect(error as? FeedbackFailure == .other) }
    }

    @Test func redirectsAreNotFollowed() async {
        let elsewhere = URL(string: "https://elsewhere.example/")!
        let redirect = RedirectSession(redirects: [endpoint: elsewhere], body: Data(#"{"number":1}"#.utf8))
        let client = FeedbackClient(endpoint: endpoint, session: redirect.session)!
        do { _ = try await client.send(submission); Issue.record("should have thrown") }
        catch { #expect(error as? FeedbackFailure == .other) }
        #expect(redirect.requests.count == 1)
    }

    @Test func httpEndpointRefused() {
        #expect(FeedbackClient(endpoint: URL(string: "http://x")!, session: RefusedURLProtocol.session) == nil)
        #expect(FeedbackRelay.client(endpoint: nil, versions: versions, session: RefusedURLProtocol.session) == nil)
    }

    @Test func aGoodEndpointGivesAClient() {
        #expect(FeedbackRelay.client(endpoint: endpoint, versions: versions, session: RefusedURLProtocol.session) != nil)
    }

    @Test func versionsTheRelayRejectsGiveNoClient() {
        for (v, m) in [("?", "26.1.0"), ("0.8.0", "?"), ("", "26.1.0"), ("0.8.0-beta.1", "26.1.0x"), ("1.2.3.4.5", "26.1.0")] {
            #expect(FeedbackRelay.client(endpoint: endpoint, versions: AppVersions(version: v, macOS: m),
                                         session: RefusedURLProtocol.session) == nil, "\(v) \(m)")
        }
        #expect(FeedbackRelay.client(endpoint: endpoint, versions: AppVersions(version: "0.8.0-beta.1", macOS: "26.1.0"),
                                     session: RefusedURLProtocol.session) != nil)
    }

    @Test func sentencesAreTheSpecs() {
        #expect(FeedbackFailure.daily.sentence == "Feedback is full for today. Try again tomorrow, or open it in GitHub.")
        #expect(FeedbackFailure.tooMany.sentence == "Too many sent just now. Try again in a minute.")
        #expect(FeedbackFailure.off.sentence == "Feedback is switched off for now.")
        #expect(FeedbackFailure.secret.sentence == "That looks like it contains a password or key. Remove it and send again.")
        #expect(FeedbackFailure.tooLong.sentence == "That’s too long to send. Shorten it, or open it in GitHub.")
        #expect(FeedbackFailure.other.sentence == "Couldn’t send your feedback.")
    }

    @Test func privateSessionKeepsNothing() {
        let configuration = FeedbackClient.privateSession().configuration
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCache == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
    }
}
