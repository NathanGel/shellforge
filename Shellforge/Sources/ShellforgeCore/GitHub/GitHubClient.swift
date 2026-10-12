// Ported from AiTerm (app/Sources/AiTermCore/GitHub/GitHubClient.swift), GPLv3, Laurens D'Hondt.
import Foundation

public struct GitHubConfig: Equatable, Sendable {
    public var token: String
    public init(token: String) { self.token = token }
}

public enum GitHubError: Error, Equatable, LocalizedError {
    case unauthorized, forbidden, network(String), badResponse(Int), decoding, repoNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized: return "Check your GitHub access token in Settings."
        // GitHub answers both a token without access to the repository and a spent rate limit with 403.
        case .forbidden: return "GitHub refused: the token can’t read this repository, or the rate limit was reached."
        case .network(let message): return "Couldn’t connect to GitHub. \(message)"
        case .badResponse(let status): return "GitHub returned an error (HTTP \(status)). Try again."
        case .decoding: return "Couldn’t read GitHub’s response. Try again."
        case .repoNotFound(let path): return "GitHub has no repository at \(path), or your token cannot see it."
        }
    }
}

/// github.com's REST API with the token from Settings. `Authorization` is one of
/// `HTTPJSON.credentialHeaders`, so the token never follows a redirect off `api.github.com`.
public struct GitHubClient: Sendable {
    let config: GitHubConfig, session: URLSession
    public init(config: GitHubConfig, session: URLSession = .shared) { self.config = config; self.session = session }

    static let api = "https://api.github.com"
    /// How many open pull requests one search reads, and how many it shows.
    static let readLimit = 100, shownLimit = 25

    public func testConnection() async throws -> String {
        struct User: Decodable { var login: String }
        return try await get(User.self, path: "/user", notFound: .badResponse(404)).login
    }

    /// GitHub's search API does not return a pull request's branch, so the newest open ones are
    /// read and filtered here, by title, branch or author. Typing a number fetches that one.
    public func pullRequests(repo: String, search: String) async throws -> [MergeRequest] {
        let base = "/repos/\(repo)/pulls"
        let text = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = Self.number(text) {
            do { return [try await get(PullPayload.self, path: base + "/\(number)", notFound: .repoNotFound(repo)).mergeRequest] }
            catch GitHubError.repoNotFound { return [] }
        }
        let query = [URLQueryItem(name: "state", value: "open"), URLQueryItem(name: "sort", value: "updated"),
                     URLQueryItem(name: "direction", value: "desc"), URLQueryItem(name: "per_page", value: String(Self.readLimit))]
        let open = try await get([Lenient<PullPayload>].self, path: base, query: query, notFound: .repoNotFound(repo))
            .compactMap { $0.value?.mergeRequest }
        let matching = text.isEmpty ? open : open.filter { pull in
            [pull.title, pull.sourceBranch, pull.author ?? ""].contains { $0.range(of: text, options: .caseInsensitive) != nil }
        }
        return Array(matching.prefix(Self.shownLimit))
    }

    /// `87`, `#87`, or GitLab's `!87` from habit.
    static func number(_ text: String) -> Int? {
        guard text.range(of: #"^[#!]?\d+$"#, options: .regularExpression) != nil else { return nil }
        return Int(text.drop { $0 == "#" || $0 == "!" })
    }

    private func get<Payload: Decodable>(_ type: Payload.Type, path: String, query: [URLQueryItem] = [],
                                         notFound: GitHubError) async throws -> Payload {
        guard let url = HTTPJSON.url(Self.api + path, query: query) else { throw GitHubError.decoding }
        let request = HTTPJSON.request(url, headers: ["Authorization": "Bearer \(config.token)", "Accept": "application/vnd.github+json",
                                                      "X-GitHub-Api-Version": "2022-11-28"])
        return try await HTTPJSON.decode(type, request, session: session) { Self.error(for: $0, notFound: notFound) }.value
    }

    /// `notFound` is what a 404 means for the path asked.
    static func error(for failure: HTTPJSON.Failure, notFound: GitHubError) -> GitHubError {
        switch failure {
        case .transport(let error): return .network(error.localizedDescription)
        case .undecodable: return .decoding
        case .status(401): return .unauthorized
        case .status(403): return .forbidden
        case .status(404): return notFound
        case .status(let status): return .badResponse(status)
        }
    }
}

/// The fields of a pull request the picker shows.
private struct PullPayload: Decodable {
    struct User: Decodable { var login: String? }
    struct Repo: Decodable { var fullName: String? }
    struct Ref: Decodable { var ref: String, label: String?, repo: Repo? }
    var number: Int, title: String, htmlUrl: String, draft: Bool?, user: User?, head: Ref, base: Ref
    /// A pull request fetched by number can be closed or merged; the list holds open ones only,
    /// and omits `merged`.
    var state: String?, merged: Bool?

    /// A head in another repository — or in none, once its fork was deleted — is a fork's.
    var mergeRequest: MergeRequest {
        let headRepo = head.repo?.fullName?.lowercased(), baseRepo = base.repo?.fullName?.lowercased()
        let fork = headRepo == nil || headRepo != baseRepo
        return MergeRequest(iid: number, title: title, sourceBranch: head.ref, targetBranch: base.ref,
                            author: user?.login, state: merged == true ? "merged" : (state ?? "open"),
                            draft: draft ?? false, url: htmlUrl,
                            forkHead: fork ? (head.label ?? "ghost:\(head.ref)") : nil)
    }
}
