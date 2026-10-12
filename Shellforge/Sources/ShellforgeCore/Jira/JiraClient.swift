// Ported from AiTerm (app/Sources/AiTermCore/Jira/JiraClient.swift), GPLv3, Laurens D'Hondt.
import Foundation

public struct JiraConfig: Equatable, Sendable { public let siteURL: URL, email: String, token: String
    public init(siteURL: URL, email: String, token: String) {
        self.siteURL = Self.normalizedSiteURL(siteURL); self.email = email; self.token = token
    }

    public static func normalizedSiteURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.password = nil
        components.user = nil
        if (components.scheme == "https" && components.port == 443)
            || (components.scheme == "http" && components.port == 80) {
            components.port = nil
        }
        components.query = nil
        components.fragment = nil
        while components.path.count > 1 && components.path.hasSuffix("/") { components.path.removeLast() }
        if components.path == "/" { components.path = "" }
        return components.url ?? url
    }
}

public enum JiraError: Error, Equatable, LocalizedError {
    case unauthorized, network(String), badResponse(Int), decoding
    case projectSiteMismatch(linked: URL, configured: URL)

    public var errorDescription: String? {
        switch self {
        case .unauthorized: return "Check your Jira email and API token in Settings."
        case .network(let message): return "Couldn’t connect to Jira. \(message)"
        case .badResponse(let status): return "Jira returned an error (HTTP \(status)). Try again."
        case .decoding: return "Couldn’t read Jira’s response. Try again."
        case .projectSiteMismatch(let linked, let configured):
            return "This project is linked to Jira at \(linked.absoluteString), but Settings is connected to \(configured.absoluteString). Remove it in Jira Projects… and link it again."
        }
    }
}

public struct JiraClient: Sendable {
    let config: JiraConfig, session: URLSession
    public init(config: JiraConfig, session: URLSession = .shared) { self.config = config; self.session = session }

    public static let openIssuesJQL = "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC"

    public func myOpenIssues(projects: [JiraProjectRef] = []) async throws -> [JiraTicket] {
        try await search(jql: Self.scoped(Self.openIssuesJQL, in: try projectScope(projects)))
    }

    /// A key (`SHOP-12`, `shop-1`) finds that ticket in any status, then open tickets whose key starts
    /// with it. A number, with projects linked, does the same for that number in each of them and
    /// adds the tickets whose text mentions it. Anything else, and a number with no project to key
    /// it to, is a text search of open tickets.
    public func search(text: String, projects: [JiraProjectRef] = []) async throws -> [JiraTicket] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = try projectScope(projects)
        let textJQL = Self.scoped("text ~ \"\(Self.textQuery(t))\" AND statusCategory != Done ORDER BY updated DESC", in: scope)
        let projectKeys = projects.map { $0.key.uppercased() }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        if let key = Self.issueKey(t) {
            return try await searchKeys([key], scope: scope, projectKeys: projectKeys) { $0.hasPrefix(key) }
        }
        guard !projectKeys.isEmpty, t.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil else {
            return try await search(jql: textJQL)
        }
        let number = Self.withoutLeadingZeros(Substring(t))
        async let byKey = searchKeys(projectKeys.map { "\($0)-\(number)" }, scope: scope, projectKeys: projectKeys) {
            Self.number(of: $0).hasPrefix(number)
        }
        async let byText = search(jql: textJQL)
        return Self.merged(try await byKey, try await byText)
    }

    /// `text` as an issue key, upper-cased and its number without leading zeros; nil if it is not
    /// one. Jira's default key format needs a project key of two characters or more.
    private static func issueKey(_ text: String) -> String? {
        let key = text.uppercased()
        guard key.range(of: #"^[A-Z][A-Z0-9_]+-[0-9]+$"#, options: .regularExpression) != nil,
              let separator = key.lastIndex(of: "-") else { return nil }
        return String(key[...separator]) + withoutLeadingZeros(key[key.index(after: separator)...])
    }

    private static func withoutLeadingZeros(_ digits: Substring) -> String {
        let trimmed = digits.drop { $0 == "0" }
        return trimmed.isEmpty ? "0" : String(trimmed)
    }

    private static func number(of key: String) -> Substring {
        key.lastIndex(of: "-").map { key[key.index(after: $0)...] } ?? ""
    }

    /// `exact`, each looked up with `key =` so it is found in any status and under a key it moved
    /// from; then Jira's picker suggestions for each whose key satisfies `matching`, open only.
    /// JQL cannot use `~` on issue keys, and the picker leaves out description and status, so the
    /// suggestions' full fields come from a second search. The picker requests run side by side,
    /// with the exact lookups.
    private func searchKeys(_ exact: [String], scope: String, projectKeys: [String],
                            matching: @escaping @Sendable (String) -> Bool) async throws -> [JiraTicket] {
        async let found = lookUp(exact, jql: { "key = \"\($0)\"" }, scope: scope)
        let suggested = try await suggestions(for: exact, scope: scope, projectKeys: projectKeys, matching: matching)
            .filter { !exact.contains($0) }
        let open = try await tickets(Array(suggested.prefix(Self.maxResults)), scope: scope)
        return Self.merged(try await found, open)
    }

    /// The picker's suggested keys for each query, in its own order — most recently updated first —
    /// taken from each query in turn so one project's many matches do not crowd out another's.
    private func suggestions(for queries: [String], scope: String, projectKeys: [String],
                             matching: @escaping @Sendable (String) -> Bool) async throws -> [String] {
        let currentJQL = (scope.isEmpty ? "" : scope + " ") + "ORDER BY updated DESC"
        let lists = try await Self.inOrder(queries) { query in
            let picker = try await decode(PickerResponse.self, request(path: "/rest/api/3/issue/picker", queryItems: [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "currentJQL", value: currentJQL),
                URLQueryItem(name: "showSubTasks", value: "true"),
            ]))
            return picker.sections.compactMap(\.value).flatMap { section -> [String] in
                // Current Search keeps to currentJQL; History does not, so it is filtered here.
                let scoped = projectKeys.isEmpty || section.id == "cs"
                return section.issues.compactMap { issue in
                    guard let key = issue.value?.key, Self.issueKey(key) == key, matching(key),
                          scoped || projectKeys.contains(String(key[..<key.lastIndex(of: "-")!])) else { return nil }
                    return key
                }
            }
        }
        var keys: [String] = []
        for rank in 0..<(lists.map(\.count).max() ?? 0) {
            for list in lists where rank < list.count && !keys.contains(list[rank]) { keys.append(list[rank]) }
        }
        return keys
    }

    /// The open tickets among `keys`, in their order. Jira answers 400 for the whole `key in (…)`
    /// when one key no longer resolves; each is then looked up alone, so only that one is lost.
    private func tickets(_ keys: [String], scope: String) async throws -> [JiraTicket] {
        guard !keys.isEmpty else { return [] }
        let list = keys.map { "\"\($0)\"" }.joined(separator: ", ")
        let found: [JiraTicket]
        do { found = try await search(jql: Self.scoped("key in (\(list)) AND statusCategory != Done", in: scope)) }
        catch JiraError.badResponse(400) {
            found = try await lookUp(keys, jql: { "key = \"\($0)\" AND statusCategory != Done" }, scope: scope)
        }
        let byKey = Dictionary(found.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        return keys.compactMap { byKey[$0] }
    }

    /// One search per key, a few at a time, in `keys` order; a key Jira cannot resolve (400) finds nothing.
    private func lookUp(_ keys: [String], jql: @escaping @Sendable (String) -> String, scope: String) async throws -> [JiraTicket] {
        try await Self.inOrder(keys) { key in
            do { return try await search(jql: Self.scoped(jql(key), in: scope)) }
            catch JiraError.badResponse(400) { return [] }
        }.flatMap { $0 }
    }

    /// How many requests one fan-out has in flight. A number across ten linked projects asks for
    /// ten picker lists and ten lookups, which Jira answered with 429 when sent at once.
    static let fanOut = 4

    /// `body` for each of `items`, `width` at a time, and the results in the order of `items`. The
    /// first failure cancels the bodies still running.
    static func inOrder<Item: Sendable, Output: Sendable>(
        _ items: [Item], width: Int = fanOut, _ body: @escaping @Sendable (Item) async throws -> Output
    ) async throws -> [Output] {
        precondition(width > 0, "a fan-out of no width never starts")
        return try await withThrowingTaskGroup(of: (Int, Output).self) { group in
            var pending = items.enumerated().makeIterator()
            func startNext(in group: inout ThrowingTaskGroup<(Int, Output), Error>) {
                guard let (index, item) = pending.next() else { return }
                group.addTask { (index, try await body(item)) }
            }
            for _ in 0..<width { startNext(in: &group) }
            var results = [Output?](repeating: nil, count: items.count)
            while let (index, output) = try await group.next() {
                results[index] = output
                startNext(in: &group)
            }
            // Every item started and none finished twice, so every slot is filled.
            return results.map { $0! }
        }
    }

    /// `lists` in order, each ticket once, at most `maxResults`.
    private static func merged(_ lists: [JiraTicket]...) -> [JiraTicket] {
        var seen = Set<String>()
        return Array(lists.joined().filter { seen.insert($0.key).inserted }.prefix(maxResults))
    }

    static let maxResults = 25

    /// Jira runs `text ~` through Lucene, where these are operators: a summary pasted as the query
    /// — `[Frontend] …`, `C++`, `fix: x` — made it answer 400 or search for something else.
    static let luceneOperators = Set(#"+-&|!(){}[]^~*?\/:"#)

    /// `text` as the inside of the JQL string literal `text ~ "…"`: each Lucene operator escaped
    /// with a backslash, then the literal's own escaping — which doubles that backslash.
    static func textQuery(_ text: String) -> String {
        let lucene = text.reduce(into: "") { out, character in
            if luceneOperators.contains(character) { out.append("\\") }
            out.append(character)
        }
        return lucene.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// All Jira projects visible to the configured account, in Jira's name order.
    public func projects() async throws -> [JiraProjectRef] {
        let pageSize = 100
        var startAt = 0
        var projects: [JiraProjectRef] = []
        while true {
            let page = try await decode(ProjectPage.self, request(path: "/rest/api/3/project/search", queryItems: [
                URLQueryItem(name: "startAt", value: String(startAt)),
                URLQueryItem(name: "maxResults", value: String(pageSize)),
                URLQueryItem(name: "orderBy", value: "name"),
            ]))
            projects += page.values.compactMap(\.value).map { JiraProjectRef(id: $0.id, key: $0.key, name: $0.name, siteURL: config.siteURL) }
            startAt += page.values.count
            if page.isLast == true || page.values.isEmpty || page.total.map({ startAt >= $0 }) == true
                || (page.isLast == nil && page.total == nil && page.values.count < pageSize) { break }
        }
        return projects
    }

    public func testConnection() async throws -> String {
        let me = try await decode(Myself.self, request(path: "/rest/api/3/myself"))
        return me.displayName ?? me.emailAddress ?? "connected"
    }

    func search(jql: String) async throws -> [JiraTicket] {
        var req = request(path: "/rest/api/3/search/jql"); req.httpMethod = "POST"
        req.httpBody = try JSONEncoder().encode(SearchBody(jql: jql, maxResults: Self.maxResults,
                                                           fields: ["summary", "description", "status", "issuetype"]))
        return try await decode(SearchResponse.self, req).issues.compactMap(\.value).map { issue in
            let description = ADFText.plain(issue.fields.description?.foundationValue)
            return JiraTicket(key: issue.key, summary: issue.fields.summary, description: description.isEmpty ? nil : description,
                              issueType: issue.fields.issuetype?.value?.name, status: issue.fields.status?.value?.name,
                              url: config.siteURL.appendingPathComponent("browse/\(issue.key)").absoluteString)
        }
    }

    /// `project in (…)` for `projects`, every one of which must be on the configured site; empty
    /// for none, which leaves a search unscoped: every project the account can see.
    private func projectScope(_ projects: [JiraProjectRef]) throws -> String {
        guard !projects.isEmpty else { return "" }
        for project in projects {
            let linkedSite = JiraConfig.normalizedSiteURL(project.siteURL)
            guard linkedSite == config.siteURL else {
                throw JiraError.projectSiteMismatch(linked: linkedSite, configured: config.siteURL)
            }
        }
        let keys = projects.map { project in
            "\"" + project.key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return "project in (\(keys.joined(separator: ", ")))"
    }

    /// `jql` limited by `scope`, a `projectScope`.
    private static func scoped(_ jql: String, in scope: String) -> String {
        scope.isEmpty ? jql : scope + " AND " + jql
    }

    private func request(path: String, queryItems: [URLQueryItem] = []) -> URLRequest {
        let base = config.siteURL.appendingPathComponent(path)
        return HTTPJSON.request(HTTPJSON.url(base.absoluteString, query: queryItems) ?? base, headers: [
            "Authorization": "Basic " + Data("\(config.email):\(config.token)".utf8).base64EncodedString(),
            "Content-Type": "application/json", "Accept": "application/json",
        ])
    }

    /// Jira's own keys are camelCase, and an ADF description holds keys of its own, so no key strategy.
    private func decode<Response: Decodable>(_ type: Response.Type, _ request: URLRequest) async throws -> Response {
        try await HTTPJSON.decode(type, request, session: session, decoder: JSONDecoder()) { failure in
            switch failure {
            case .transport(let error): return JiraError.network(error.localizedDescription)
            case .undecodable: return .decoding
            case .status(401), .status(403): return .unauthorized
            case .status(let status): return .badResponse(status)
            }
        }.value
    }
}

private struct SearchBody: Encodable {
    var jql: String, maxResults: Int, fields: [String]
}

/// A page of `/search/jql`: the issues that have a key and a summary, each other dropped alone.
private struct SearchResponse: Decodable {
    struct Issue: Decodable { var key: String, fields: Fields }
    struct Fields: Decodable {
        var summary: String
        /// Atlassian Document Format, or plain text; `ADFText` reads either.
        var description: StoredJSON?
        var issuetype: Lenient<Named>?, status: Lenient<Named>?
    }
    struct Named: Decodable { var name: String? }
    var issues: [Lenient<Issue>]
}

/// `/issue/picker`: its sections of suggested issue keys. A section that is not one drops alone.
private struct PickerResponse: Decodable {
    struct Section: Decodable {
        var id: String?, issues: [Lenient<Suggestion>]
        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: Key.self)
            id = fields.lenient(String.self, forKey: .id)
            issues = fields.lenient([Lenient<Suggestion>].self, forKey: .issues) ?? []
        }
        private enum Key: String, CodingKey { case id, issues }
    }
    struct Suggestion: Decodable { var key: String }
    var sections: [Lenient<Section>]
}

/// A page of `/project/search`. `values` keeps its malformed entries as empty ones, so `startAt`
/// advances past them. The paging fields it may send wrongly are read as not sent.
private struct ProjectPage: Decodable {
    struct Project: Decodable { var id: String, key: String, name: String }
    var values: [Lenient<Project>]
    var isLast: Bool?, total: Int?

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: Key.self)
        values = try fields.decode([Lenient<Project>].self, forKey: .values)
        isLast = fields.lenient(Bool.self, forKey: .isLast)
        total = fields.lenient(Int.self, forKey: .total)
    }
    private enum Key: String, CodingKey { case values, isLast, total }
}

private struct Myself: Decodable {
    var displayName: String?, emailAddress: String?

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: Key.self)
        displayName = fields.lenient(String.self, forKey: .displayName)
        emailAddress = fields.lenient(String.self, forKey: .emailAddress)
    }
    private enum Key: String, CodingKey { case displayName, emailAddress }
}
