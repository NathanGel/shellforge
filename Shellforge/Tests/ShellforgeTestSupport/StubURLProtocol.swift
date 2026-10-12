// Ported from AiTerm (app/Tests/AiTermTestSupport/StubURLProtocol.swift), GPLv3, Laurens D'Hondt.
import Foundation
import ShellforgeCore

/// A stubbed URL protocol shared by every AiTermCore network-client test. State used to live in
/// two global `static var`s (`handler`, `lastRequest`), which was fine while `JiraClientTests`
/// was its only consumer. Once `GitLabClientTests` started stubbing through the same class,
/// Swift Testing's cross-suite parallelism raced both suites on that shared mutable state, so
/// storage is now keyed by a private per-session token instead: each `StubSession` gets its own
/// slot, isolated from every other test's.
final class StubURLProtocol: URLProtocol {
    static let tokenHeader = "X-Stub-Token"

    typealias Handler = @Sendable (URLRequest) -> (Int, Data)
    private struct Store {
        var handlers: [String: Handler] = [:]
        var lastRequests: [String: URLRequest] = [:]
        var requests: [String: [URLRequest]] = [:]
    }
    private static let store = Locked(Store())

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession converts a POST body from `httpBody` into `httpBodyStream` before handing the
        // request to the protocol, so `request.httpBody` is always nil here. Drain the stream back
        // into `httpBody` on the recorded copy so tests can inspect the body via `lastRequest`, and
        // hand the handler that copy too.
        var recorded = request
        if recorded.httpBody == nil, let stream = request.httpBodyStream {
            recorded.httpBody = Self.drain(stream)
        }
        let token = request.value(forHTTPHeaderField: Self.tokenHeader) ?? ""
        let handler = Self.store.withLock {
            $0.lastRequests[token] = recorded
            $0.requests[token, default: []].append(recorded)
            return $0.handlers[token]
        }
        let (status, data) = handler!(recorded)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    fileprivate static func register(_ token: String, handler: @escaping Handler) {
        store.withLock { $0.handlers[token] = handler }
    }
    fileprivate static func lastRequest(for token: String) -> URLRequest? {
        store.withLock { $0.lastRequests[token] }
    }
    fileprivate static func requests(for token: String) -> [URLRequest] {
        store.withLock { $0.requests[token] ?? [] }
    }

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

/// One test's private stub: its own handler and its own view of the last request it received,
/// carried through `StubURLProtocol`'s per-token storage via the `X-Stub-Token` header added to
/// every request this session sends. A test that swaps its handler mid-test creates a fresh
/// `StubSession` per handler rather than mutating a shared one.
final class StubSession {
    private let token = UUID().uuidString
    let session: URLSession

    init(handler: @escaping StubURLProtocol.Handler) {
        StubURLProtocol.register(token, handler: handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = [StubURLProtocol.tokenHeader: token]
        session = URLSession(configuration: configuration)
    }

    var lastRequest: URLRequest? { StubURLProtocol.lastRequest(for: token) }
    /// Every request received, in arrival order — which is not send order for requests in flight together.
    var requests: [URLRequest] { StubURLProtocol.requests(for: token) }
}

/// A session whose every request fails as a refused connection does, without dialling anything.
final class RefusedURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)) }
    override func stopLoading() {}

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RefusedURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}
