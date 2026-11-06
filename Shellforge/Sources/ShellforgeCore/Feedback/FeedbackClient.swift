import Foundation

/// Why feedback was not sent, each with the one sentence the form shows.
public enum FeedbackFailure: Error, Equatable, Sendable {
    case daily, tooMany, off, secret, tooLong, other

    public var sentence: String {
        switch self {
        case .daily: return "Feedback is full for today. Try again tomorrow, or open it in GitHub."
        case .tooMany: return "Too many sent just now. Try again in a minute."
        case .off: return "Feedback is switched off for now."
        case .secret: return "That looks like it contains a password or key. Remove it and send again."
        case .tooLong: return "That’s too long to send. Shorten it, or open it in GitHub."
        case .other: return "Couldn’t send your feedback."
        }
    }
}

public enum FeedbackRelay {
    /// The relay's address: `<worker url>/feedback`, or the bare Worker URL, to which the client adds `/feedback`.
    /// Nil sends feedback through GitHub instead (`feedback-relay/README.md` sets one up).
    public static let endpoint: URL? = URL(string: "https://shellforge-feedback.nathan-geleyn.workers.dev/feedback")

    /// The relay's pattern for `version` and `macos` (`feedback-relay/src/validate.js`).
    private static func relayAccepts(_ version: String) -> Bool {
        version.wholeMatch(of: #/[0-9]{1,4}(\.[0-9]{1,4}){0,3}(-[0-9A-Za-z.]{1,16})?/#) != nil
    }

    /// A client, or nil when there is no relay, it is not https, or the relay would refuse these
    /// versions (`AppVersions` says `?` when the bundle has none): the caller falls back to GitHub.
    public static func client(endpoint: URL? = endpoint, versions: AppVersions = .current,
                              session: URLSession? = nil) -> FeedbackClient? {
        guard let endpoint,
              relayAccepts(versions.version), relayAccepts(versions.macOS) else { return nil }
        // Built only now, so a call that returns nil never makes a session.
        return FeedbackClient(endpoint: endpoint, session: session ?? FeedbackClient.privateSession())
    }
}

public struct FeedbackClient: Sendable {
    /// Where feedback is posted: the endpoint as given when it has a path, else the endpoint plus `/feedback`.
    private let url: URL
    private let session: URLSession

    /// Nil unless `endpoint` is https: feedback never travels in the clear.
    public init?(endpoint: URL, session: URLSession) {
        guard endpoint.scheme?.lowercased() == "https" else { return nil }
        var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        if parts?.path.isEmpty ?? true || parts?.path == "/" { parts?.path = "/feedback" }
        guard let url = parts?.url else { return nil }
        self.url = url
        self.session = session
    }

    /// Posts `feedback` and returns the number of the issue the relay made. Throws `FeedbackFailure`,
    /// or `CancellationError` when the task is cancelled.
    public func send(_ feedback: FeedbackSubmission) async throws -> Int {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(feedback)

        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request, delegate: NoRedirects()) }
        catch {
            if error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw FeedbackFailure.other
        }
        guard let http = response as? HTTPURLResponse else { throw FeedbackFailure.other }
        let code = (try? JSONDecoder().decode(Reply.self, from: data))
        switch http.statusCode {
        case 201:
            guard let number = code?.number else { throw FeedbackFailure.other }
            return number
        case 429: throw code?.error == "daily" ? FeedbackFailure.daily : .tooMany
        case 503: throw FeedbackFailure.off
        case 400 where code?.error == "secret": throw FeedbackFailure.secret
        case 400 where code?.error == "size" || code?.error == "fields": throw FeedbackFailure.tooLong
        default: throw FeedbackFailure.other
        }
    }

    /// No cookies, cache or stored credentials: the relay is anonymous and so is the request.
    public static func privateSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }

    private struct Reply: Decodable {
        let number: Int?
        let error: String?
    }
}

/// Refuses every redirect, so the answer is the relay's own.
///
/// The completion-handler form, not the `async` one, for the reason `CredentialGuard` gives: an
/// `async` delegate method waits for a free worker of Swift's cooperative pool.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
