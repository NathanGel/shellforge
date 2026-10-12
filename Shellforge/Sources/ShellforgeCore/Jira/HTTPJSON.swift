// Ported from AiTerm (app/Sources/AiTermCore/HTTPJSON.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// The request round the REST clients share — Jira, GitLab, GitHub and the release feeds. It builds
/// the request, sends it, tells a transport failure from a status outside 2xx from a body that is
/// not what was asked for, and decodes it; each client turns those into its own error with one
/// `mapping`. Cancellation stays cancellation: a search dropped for a newer one is not a network
/// failure to report.
///
/// No credential leaves its origin. URLSession re-sends every header of the first request on each
/// redirect hop, so a server that redirects elsewhere — GitLab sends a package download to object
/// storage — would hand the token to whatever it names. Every hop off the first request's origin
/// (scheme, host and port) loses `credentialHeaders`.
enum HTTPJSON {
    enum Failure: Error {
        case transport(Error)
        /// Any status outside 2xx; `0` for a response that is not HTTP at all.
        case status(Int)
        /// A 2xx whose body does not decode as the type asked for.
        case undecodable(status: Int)
    }

    /// Jira's and GitHub's `Authorization`, and GitLab's `PRIVATE-TOKEN`.
    static let credentialHeaders = ["Authorization", "PRIVATE-TOKEN"]

    /// A request for `url` with `headers`. The clients' timeout is 15 s; a download passes its own.
    static func request(_ url: URL, headers: [String: String], timeout: TimeInterval = 15) -> URLRequest {
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.timeoutInterval = timeout
        return request
    }

    /// `string` with `query` appended; nil when it is no URL. `URLComponents(string:)` keeps a
    /// percent-encoded path verbatim, which `url.appendingPathComponent` would not.
    static func url(_ string: String, query: [URLQueryItem] = []) -> URL? {
        guard var components = URLComponents(string: string) else { return nil }
        if !query.isEmpty { components.queryItems = query }
        return components.url
    }

    /// `send`, then the body decoded as `Value`, with the status it came with.
    static func decode<Value: Decodable>(_ type: Value.Type, _ request: URLRequest, session: URLSession,
                                         decoder: JSONDecoder = .snakeCase) async throws -> (value: Value, status: Int) {
        let (data, response) = try await send(request, session: session)
        do { return (try decoder.decode(Value.self, from: data), response.statusCode) }
        catch {
            // The person is told the answer was not what was expected; which field, only here.
            HTTPLog.failed("Reading \(request.url?.path ?? "a response") as \(Value.self)", error)
            throw Failure.undecodable(status: response.statusCode)
        }
    }

    /// `decode` with each `Failure` turned into the client's own error by `mapping`; a cancellation
    /// passes through as it is.
    static func decode<Value: Decodable, Mapped: Error>(
        _ type: Value.Type, _ request: URLRequest, session: URLSession, decoder: JSONDecoder = .snakeCase,
        mapping: (Failure) -> Mapped
    ) async throws -> (value: Value, status: Int) {
        do { return try await decode(type, request, session: session, decoder: decoder) }
        catch let failure as Failure { throw mapping(failure) }
    }

    static func send(_ request: URLRequest, session: URLSession) async throws -> (Data, HTTPURLResponse) {
        let guarded = CredentialGuard(origin: request.url)
        let (data, response) = try await transfer { try await session.data(for: request, delegate: guarded) }
        return (data, try check(response))
    }

    /// `send` for a body streamed to a temporary file, which the caller moves or deletes. A file
    /// that came with a failed status is deleted here.
    static func download(_ request: URLRequest, session: URLSession) async throws -> (URL, HTTPURLResponse) {
        let guarded = CredentialGuard(origin: request.url)
        let (file, response) = try await transfer { try await session.download(for: request, delegate: guarded) }
        do { return (file, try check(response)) }
        catch { try? FileManager.default.removeItem(at: file); throw error }
    }

    private static func transfer<Value>(_ body: () async throws -> Value) async throws -> Value {
        do { return try await body() }
        catch {
            // URLSession reports a cancelled task as `URLError.cancelled`.
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw Failure.transport(error)
        }
    }

    private static func check(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw Failure.status(0) }
        guard (200..<300).contains(http.statusCode) else { throw Failure.status(http.statusCode) }
        return http
    }
}

extension JSONDecoder {
    /// GitHub's and GitLab's payloads are snake_case.
    static let snakeCase: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

/// An element of a JSON list that may not decode, so one malformed entry drops only itself.
struct Lenient<Value: Decodable>: Decodable {
    var value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

extension KeyedDecodingContainer {
    /// `key` as `Value`, or nil when it is absent, null or of another type: one odd field of a
    /// payload that has others worth reading is treated as not sent.
    func lenient<Value: Decodable>(_ type: Value.Type, forKey key: Key) -> Value? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

/// Drops the credentials from a redirect that leaves the first request's origin.
///
/// The completion-handler form, not the `async` one: URLSession runs an `async` delegate method as a
/// task on Swift's cooperative pool, so the redirect waited for a free worker while the request's
/// timeout ran — and with every worker busy (the parallel test runner parks them all in blocking
/// tests for longer than the timeout) the hop timed out. This form runs on the session's own queue.
private final class CredentialGuard: NSObject, URLSessionTaskDelegate, Sendable {
    let origin: URL?
    init(origin: URL?) { self.origin = origin }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, let origin, url.isSameOrigin(as: origin) else {
            var request = request
            for header in HTTPJSON.credentialHeaders { request.setValue(nil, forHTTPHeaderField: header) }
            return completionHandler(request)
        }
        completionHandler(request)
    }
}

extension URL {
    /// The host as DNS compares it: case-insensitively, a trailing dot ignored.
    var comparableHost: String? {
        guard var name = host?.lowercased() else { return nil }
        while name.hasSuffix(".") { name.removeLast() }
        return name
    }

    /// The port as written, unless it is the scheme's own (443 for https, 80 for http), which
    /// names nothing the URL would not use anyway.
    var comparablePort: Int? {
        switch (scheme?.lowercased(), port) {
        case ("https", 443), ("http", 80): return nil
        default: return port
        }
    }

    func isSameOrigin(as other: URL) -> Bool {
        scheme?.lowercased() == other.scheme?.lowercased() && comparableHost == other.comparableHost && comparablePort == other.comparablePort
    }
}

import os

/// AiTerm's `Log.network`: one line for a response that could not be read.
enum HTTPLog {
    static let logger = Logger(subsystem: "io.github.nathangel.shellforge", category: "network")
    static func failed(_ what: String, _ error: Error) {
        logger.error("\(what, privacy: .public) failed: \(String(describing: error), privacy: .public)")
    }
}
