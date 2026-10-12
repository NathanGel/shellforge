// Ported from AiTerm (app/Tests/AiTermTestSupport/RedirectStub.swift), GPLv3, Laurens D'Hondt.
import Foundation
import ShellforgeCore

/// A stubbed server that answers some URLs with a `302` to another URL and everything else with
/// `200` and a fixed body, and records every request it sees in order. The redirected request it
/// hands back carries all of the original's headers, as URLSession's own redirect handling does —
/// so whatever reaches the second hop is what the client's redirect delegate let through.
/// Per-session state is keyed by a token header, exactly as in `StubURLProtocol`.
final class RedirectURLProtocol: URLProtocol {
    static let tokenHeader = "X-Redirect-Stub-Token"

    private struct Store {
        var routes: [String: (redirects: [URL: URL], body: Data)] = [:]
        var requests: [String: [URLRequest]] = [:]
    }
    private static let store = Locked(Store())

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let token = request.value(forHTTPHeaderField: Self.tokenHeader) ?? ""
        let request = self.request
        let route = Self.store.withLock {
            $0.requests[token, default: []].append(request)
            return $0.routes[token]
        }
        let url = request.url!
        if let target = route?.redirects[url] {
            var next = request
            next.url = target
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: route?.body ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    fileprivate static func register(_ token: String, redirects: [URL: URL], body: Data) {
        store.withLock { $0.routes[token] = (redirects, body) }
    }
    fileprivate static func requests(for token: String) -> [URLRequest] {
        store.withLock { $0.requests[token] ?? [] }
    }
}

final class RedirectSession {
    private let token = UUID().uuidString
    let session: URLSession

    init(redirects: [URL: URL], body: Data) {
        RedirectURLProtocol.register(token, redirects: redirects, body: body)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectURLProtocol.self]
        configuration.httpAdditionalHeaders = [RedirectURLProtocol.tokenHeader: token]
        session = URLSession(configuration: configuration)
    }

    /// Every request the stub received, first hop first.
    var requests: [URLRequest] { RedirectURLProtocol.requests(for: token) }
}
