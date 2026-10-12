// Ported from AiTerm (app/Tests/AiTermCoreTests/JiraClientTests.swift), GPLv3, Laurens D'Hondt.
import Testing
import Foundation
@testable import ShellforgeCore
@testable import ShellforgeTestSupport

@Suite struct JiraClientTests {
    let config = JiraConfig(siteURL: URL(string: "https://example.atlassian.net")!, email: "me@example.com", token: "tok")
    let issue: [String: Any] = ["key": "WEB-5447", "fields": ["summary": "Add graceful SIGTERM", "status": ["name": "In Progress"], "issuetype": ["name": "Task"],
                                                            "description": ["type": "doc", "content": [["type": "paragraph", "content": [["type": "text", "text": "Drain tasks."]]]]]]]

    @Test func testMyOpenIssuesParsesAndAuthenticates() async throws {
        let page = try JSONSerialization.data(withJSONObject: ["issues": [issue]])
        let stub = StubSession { _ in (200, page) }
        let tickets = try await JiraClient(config: config, session: stub.session).myOpenIssues()
        #expect(tickets == [JiraTicket(key: "WEB-5447", summary: "Add graceful SIGTERM", description: "Drain tasks.", issueType: "Task", status: "In Progress", url: "https://example.atlassian.net/browse/WEB-5447")])
        let req = stub.lastRequest!
        #expect(req.url?.path == "/rest/api/3/search/jql")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("me@example.com:tok".utf8).base64EncodedString())
        let body = try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]
        #expect(body?["jql"] as? String == "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC")
    }

    @Test func testSearchByKeyAndByText() async throws {
        let stub = keyStub()
        let client = JiraClient(config: config, session: stub.session)
        _ = try await client.search(text: "shop-1713")
        #expect(pickerQueries(stub) == ["SHOP-1713"])
        #expect(stub.requests.compactMap { pickerValue("currentJQL", of: $0) } == ["ORDER BY updated DESC"])
        #expect(jqls(stub) == [#"key = "SHOP-1713""#])
        _ = try await client.search(text: "sigterm \"worker\"")
        #expect(jql(stub) == "text ~ \"sigterm \\\"worker\\\"\" AND statusCategory != Done ORDER BY updated DESC")
    }

    @Test func partialKeySearchReturnsExactAndLongerKeysWithFullDetails() async throws {
        let stub = StubSession { request in
            if request.url?.path == "/rest/api/3/issue/picker" {
                #expect(pickerValue("query", of: request) == "WEB-55")
                return (200, Data(#"{"sections":[{"id":"cs","issues":[{"key":"WEB-5595"},{"key":"WEB-55"},{"key":"WEB-155"}]},{"id":"hs","issues":[{"key":"WEB-55"}]}]}"#.utf8))
            }
            if jqlBody(request) == #"key = "WEB-55""# {
                return (200, Data(#"{"issues":[{"key":"WEB-55","fields":{"summary":"Exact","description":"Details","status":{"name":"Done"}}}]}"#.utf8))
            }
            #expect(jqlBody(request) == #"key in ("WEB-5595") AND statusCategory != Done"#)
            return (200, Data(#"{"issues":[{"key":"WEB-5595","fields":{"summary":"Longer"}}]}"#.utf8))
        }
        let tickets = try await JiraClient(config: config, session: stub.session).search(text: "  web-55\n")
        #expect(tickets.map(\.key) == ["WEB-55", "WEB-5595"])
        #expect(tickets.first?.status == "Done")
        #expect(tickets.first?.summary == "Exact")
        #expect(tickets.first?.description == "Details")
    }

    /// The picker suggests only some keys, and never one the issue has moved from; `key =` finds
    /// both, so a typed full key always reaches its ticket.
    @Test func aFullKeyFindsItsTicketEvenWhenMovedOrNotSuggested() async throws {
        let stub = keyStub(search: { $0 == #"project in ("SHOP") AND key = "SUP-12""# ? ["SHOP-40"] : [] })
        let tickets = try await JiraClient(config: config, session: stub.session).search(text: "sup-12", projects: [app])
        #expect(tickets.map(\.key) == ["SHOP-40"])
    }

    @Test func aKeyJiraCannotResolveStillListsLongerKeys() async throws {
        let stub = keyStub(picker: ["SHOP-1": ["SHOP-10", "SHOP-11"]], search: { $0 == #"key = "SHOP-1""# ? nil : ["SHOP-10", "SHOP-11"] })
        let tickets = try await JiraClient(config: config, session: stub.session).search(text: "SHOP-1")
        #expect(tickets.map(\.key) == ["SHOP-10", "SHOP-11"])
    }

    /// Jira fails the whole `key in (…)` when one key in it no longer resolves.
    @Test func aSuggestedKeyThatNoLongerResolvesDropsOnlyItself() async throws {
        let stub = keyStub(picker: ["SHOP-1": ["SHOP-10", "SHOP-11"]], search: { jql in
            jql.hasPrefix("key in") || jql.hasPrefix(#"key = "SHOP-11""#) ? nil : jql.hasPrefix(#"key = "SHOP-10""#) ? ["SHOP-10"] : []
        })
        let tickets = try await JiraClient(config: config, session: stub.session).search(text: "SHOP-1")
        #expect(tickets.map(\.key) == ["SHOP-10"])
        #expect(Set(jqls(stub)) == [#"key = "SHOP-1""#, #"key in ("SHOP-10", "SHOP-11") AND statusCategory != Done"#,
                                    #"key = "SHOP-10" AND statusCategory != Done"#, #"key = "SHOP-11" AND statusCategory != Done"#])
    }

    /// Exact numbers first, then the picker's most recently updated matches taken from each project
    /// in turn, then tickets whose text mentions the number.
    @Test func numericSearchRanksExactKeysThenEachProjectsSuggestionsThenText() async throws {
        let scope = #"project in ("SHOP", "PAY")"#
        let stub = keyStub(picker: ["SHOP-2": ["SHOP-20", "SHOP-2", "SHOP-200"], "PAY-2": ["PAY-2", "PAY-21"]],
                           history: ["SHOP-2": ["SUP-2"]], search: { jql in
            switch jql {
            case scope + #" AND key = "SHOP-2""#: ["SHOP-2"]
            case scope + #" AND key = "PAY-2""#: ["PAY-2"]
            case scope + #" AND key in ("SHOP-20", "PAY-21", "SHOP-200") AND statusCategory != Done"#: ["SHOP-200", "SHOP-20", "PAY-21"]
            case scope + #" AND text ~ "2" AND statusCategory != Done ORDER BY updated DESC"#: ["SHOP-7", "SHOP-2"]
            default: nil
            }
        })
        let tickets = try await JiraClient(config: config, session: stub.session).search(text: "2", projects: [app, ops])
        #expect(tickets.map(\.key) == ["SHOP-2", "PAY-2", "SHOP-20", "PAY-21", "SHOP-200", "SHOP-7"])
        #expect(Set(pickerQueries(stub)) == ["SHOP-2", "PAY-2"])
        #expect(Set(stub.requests.compactMap { pickerValue("currentJQL", of: $0) }) == [scope + " ORDER BY updated DESC"])
    }

    /// With no project to put it in, a number is no key; it may still be in a title.
    @Test func aNumberWithoutLinkedProjectsIsATextSearch() async throws {
        let stub = keyStub()
        _ = try await JiraClient(config: config, session: stub.session).search(text: "404")
        #expect(pickerQueries(stub).isEmpty)
        #expect(jqls(stub) == [#"text ~ "404" AND statusCategory != Done ORDER BY updated DESC"#])
    }

    /// Jira's default key format needs a project key of two characters or more.
    @Test func aOneLetterProjectKeyIsATextSearch() async throws {
        let stub = keyStub()
        _ = try await JiraClient(config: config, session: stub.session).search(text: "B-52")
        #expect(pickerQueries(stub).isEmpty)
        #expect(jqls(stub) == [#"text ~ "B\\-52" AND statusCategory != Done ORDER BY updated DESC"#])
    }

    @Test func leadingZerosAreDroppedFromKeysButNotFromText() async throws {
        let stub = keyStub()
        let client = JiraClient(config: config, session: stub.session)
        _ = try await client.search(text: "shop-007")
        #expect(pickerQueries(stub) == ["SHOP-7"])
        #expect(jqls(stub) == [#"key = "SHOP-7""#])
        let numbers = keyStub(picker: ["SHOP-7": ["SHOP-70"]])
        _ = try await JiraClient(config: config, session: numbers.session).search(text: "07", projects: [app])
        #expect(pickerQueries(numbers) == ["SHOP-7"])
        #expect(jqls(numbers).contains(#"project in ("SHOP") AND text ~ "07" AND statusCategory != Done ORDER BY updated DESC"#))
        #expect(jqls(numbers).contains(#"project in ("SHOP") AND key in ("SHOP-70") AND statusCategory != Done"#))
    }

    /// `text ~` goes through Lucene, where these characters are operators; a summary pasted as
    /// the query — `[Frontend] …`, `C++`, `fix: x` — made Jira answer 400 or search for something
    /// else. Each takes a backslash, which the JQL string literal needs doubled.
    @Test func textSearchEscapesLuceneOperators() async throws {
        let stub = StubSession { _ in (200, Data("{\"issues\":[]}".utf8)) }
        let client = JiraClient(config: config, session: stub.session)
        let tail = " AND statusCategory != Done ORDER BY updated DESC"
        _ = try await client.search(text: "[Frontend] C++ fix: x")
        #expect(jql(stub) == #"text ~ "\\[Frontend\\] C\\+\\+ fix\\: x""# + tail)
        _ = try await client.search(text: #"a-b && c || !d (e) {f} ^g ~h *i ?j k/l"#)
        #expect(jql(stub) == #"text ~ "a\\-b \\&\\& c \\|\\| \\!d \\(e\\) \\{f\\} \\^g \\~h \\*i \\?j k\\/l""# + tail)
        _ = try await client.search(text: #"back\slash "quoted""#)
        #expect(jql(stub) == #"text ~ "back\\\\slash \"quoted\"""# + tail)
    }

    @Test func testIssueSearchesAreScopedToEveryLinkedProject() async throws {
        let stub = StubSession { _ in (200, Data("{\"issues\":[],\"sections\":[]}".utf8)) }
        let client = JiraClient(config: config, session: stub.session)
        let projects = [JiraProjectRef(id: "10001", key: "SHOP", name: "Storefront", siteURL: config.siteURL),
                        JiraProjectRef(id: "10002", key: "PAY", name: "Payments", siteURL: config.siteURL)]

        _ = try await client.myOpenIssues(projects: projects)
        #expect(jql(stub) == "project in (\"SHOP\", \"PAY\") AND assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC")
        let keys = keyStub()
        _ = try await JiraClient(config: config, session: keys.session).search(text: "pay-8773", projects: projects)
        #expect(pickerQueries(keys) == ["PAY-8773"])
        #expect(keys.requests.compactMap { pickerValue("currentJQL", of: $0) } == [#"project in ("SHOP", "PAY") ORDER BY updated DESC"#])
        #expect(jqls(keys) == [#"project in ("SHOP", "PAY") AND key = "PAY-8773""#])
        _ = try await client.search(text: "worker", projects: Array(projects.prefix(1)))
        #expect(jql(stub) == "project in (\"SHOP\") AND text ~ \"worker\" AND statusCategory != Done ORDER BY updated DESC")
        _ = try await client.search(text: "worker", projects: [])
        #expect(jql(stub) == "text ~ \"worker\" AND statusCategory != Done ORDER BY updated DESC",
                "no linked project searches every project")
    }

    @Test func testALinkedProjectKeyIsEscapedInsideItsJQLString() async throws {
        let stub = StubSession { _ in (200, Data("{\"issues\":[]}".utf8)) }
        let odd = JiraProjectRef(id: "1", key: #"A"B\C"#, name: "Odd", siteURL: config.siteURL)

        _ = try await JiraClient(config: config, session: stub.session).myOpenIssues(projects: [odd])

        #expect(jql(stub)?.hasPrefix(#"project in ("A\"B\\C") AND "#) == true)
    }

    /// Every linked project is checked against the configured site, not only the first.
    @Test func testIssueSearchRejectsASecondProjectLinkedToAnotherJiraSite() async throws {
        let stub = StubSession { _ in (200, Data("{\"issues\":[]}".utf8)) }
        let projects = [JiraProjectRef(id: "10001", key: "SHOP", name: "Storefront", siteURL: config.siteURL),
                        JiraProjectRef(id: "10002", key: "OLD", name: "Old", siteURL: URL(string: "https://old.atlassian.net")!)]

        await #expect(throws: JiraError.projectSiteMismatch(linked: URL(string: "https://old.atlassian.net")!,
                                                            configured: config.siteURL)) {
            _ = try await JiraClient(config: config, session: stub.session).myOpenIssues(projects: projects)
        }
        #expect(stub.lastRequest == nil)
    }

    @Test func testIssueSearchRejectsAProjectLinkedToAnotherJiraSite() async throws {
        let project = try JSONDecoder().decode(
            JiraProjectRef.self,
            from: Data(#"{"id":"10001","key":"SHOP","name":"Storefront","siteURL":"https://alice:secret@old.atlassian.net:443/"}"#.utf8)
        )
        let stub = StubSession { _ in (200, Data("{\"issues\":[]}".utf8)) }
        let client = JiraClient(config: config, session: stub.session)

        do {
            _ = try await client.myOpenIssues(projects: [project])
            Issue.record("Expected a Jira site mismatch")
        } catch {
            #expect(error.localizedDescription.contains("https://old.atlassian.net"))
            #expect(error.localizedDescription.contains("https://example.atlassian.net"))
            #expect(!error.localizedDescription.contains("alice"))
            #expect(!error.localizedDescription.contains("secret"))
        }
        #expect(stub.lastRequest == nil)
    }

    @Test func testIssueSearchAcceptsEquivalentJiraSiteURLs() async throws {
        let project = JiraProjectRef(
            id: "10001",
            key: "SHOP",
            name: "Storefront",
            siteURL: URL(string: "HTTPS://EXAMPLE.ATLASSIAN.NET:443/")!
        )
        let stub = StubSession { _ in (200, Data("{\"issues\":[]}".utf8)) }

        _ = try await JiraClient(config: config, session: stub.session).myOpenIssues(projects: [project])

        #expect(stub.lastRequest != nil)
    }

    @Test func testConfiguredSiteIdentityStripsCredentialsAndDefaultPort() {
        let config = JiraConfig(
            siteURL: URL(string: "https://alice:secret@EXAMPLE.ATLASSIAN.NET:443/")!,
            email: "me@example.com",
            token: "tok"
        )

        #expect(config.siteURL == URL(string: "https://example.atlassian.net")!)
    }

    @Test func testProjectsParsesTheVisibleJiraProjects() async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "isLast": true,
            "total": 2,
            "values": [
                ["id": "10001", "key": "SHOP", "name": "Storefront"],
                ["id": "10002", "key": "PAY", "name": "Payments"],
            ],
        ])
        let stub = StubSession { _ in (200, body) }
        let projects = try await JiraClient(config: config, session: stub.session).projects()

        #expect(projects == [
            JiraProjectRef(id: "10001", key: "SHOP", name: "Storefront", siteURL: config.siteURL),
            JiraProjectRef(id: "10002", key: "PAY", name: "Payments", siteURL: config.siteURL),
        ])
        let request = try #require(stub.lastRequest)
        #expect(request.url?.path == "/rest/api/3/project/search")
        let query = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.first(where: { $0.name == "startAt" })?.value == "0")
        #expect(query?.first(where: { $0.name == "maxResults" })?.value == "100")
        #expect(query?.first(where: { $0.name == "orderBy" })?.value == "name")
    }

    @Test func testProjectsLoadsEveryPage() async throws {
        let stub = StubSession { request in
            let query = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }
            let startAt = query?.first(where: { $0.name == "startAt" })?.value
            let object: [String: Any]
            if startAt == "0" {
                object = [
                    "isLast": false,
                    "total": 2,
                    "values": [["id": "10001", "key": "SHOP", "name": "Storefront"]],
                ]
            } else {
                object = [
                    "isLast": true,
                    "total": 2,
                    "values": [["id": "10002", "key": "PAY", "name": "Payments"]],
                ]
            }
            return (200, try! JSONSerialization.data(withJSONObject: object))
        }

        let projects = try await JiraClient(config: config, session: stub.session).projects()

        #expect(projects.map(\.key) == ["SHOP", "PAY"])
        let request = try #require(stub.lastRequest)
        let query = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.first(where: { $0.name == "startAt" })?.value == "1")
    }

    @Test func testUnauthorizedMapsToError() async {
        let stub = StubSession { _ in (401, Data()) }
        do { _ = try await JiraClient(config: config, session: stub.session).myOpenIssues(); Issue.record("expected throw") }
        catch let e as JiraError { #expect(e == .unauthorized) } catch { Issue.record("\(error)") }
    }

    /// URLSession re-sends every header on a redirect, so a Jira site that redirected elsewhere
    /// would hand the account's API token to whatever it named.
    @Test func credentialsDoNotFollowARedirectToAnotherHost() async throws {
        let myself = URL(string: "https://example.atlassian.net/rest/api/3/myself")!
        let elsewhere = URL(string: "https://elsewhere.example.com/myself")!
        let stub = RedirectSession(redirects: [myself: elsewhere], body: Data(#"{"displayName":"Me"}"#.utf8))
        #expect(try await JiraClient(config: config, session: stub.session).testConnection() == "Me")
        #expect(stub.requests.map(\.url) == [myself, elsewhere])
        #expect(stub.requests.first?.value(forHTTPHeaderField: "Authorization") != nil)
        #expect(stub.requests.last?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    /// A search abandoned for a newer one is cancelled, not a network failure to report.
    @Test(arguments: ["worker", "SHOP-2", "2"]) func aCancelledRequestThrowsCancellation(text: String) async {
        let stub = StubSession { _ in (200, Data("{\"issues\":[],\"sections\":[]}".utf8)) }
        let client = JiraClient(config: config, session: stub.session)
        let search = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.search(text: text)
        }
        await #expect(throws: CancellationError.self) { _ = try await search.value }
    }

    @Test func keySearchRejectsSiteMismatchBeforeSendingRequests() async {
        let stub = StubSession { _ in
            Issue.record("Site mismatch must not send a request")
            return (200, Data())
        }
        let project = JiraProjectRef(id: "1", key: "SHOP", name: "Storefront", siteURL: URL(string: "https://other.atlassian.net")!)
        await #expect(throws: JiraError.projectSiteMismatch(linked: project.siteURL, configured: config.siteURL)) {
            _ = try await JiraClient(config: config, session: stub.session).search(text: "2", projects: [project])
        }
    }

    /// History suggestions ignore `currentJQL`; Current Search keeps to it, so it is trusted.
    @Test func keySearchDiscardsHistoryFromUnlinkedProjects() async throws {
        let stub = keyStub(picker: ["SHOP-2": ["SHOP-20"]], history: ["SHOP-2": ["SUP-2", "SHOP-21"]], search: { jql in
            jql.contains("key in") ? ["SHOP-20", "SHOP-21"] : []
        })
        let tickets = try await JiraClient(config: config, session: stub.session).search(text: "SHOP-2", projects: [app])
        #expect(tickets.map(\.key) == ["SHOP-20", "SHOP-21"])
        #expect(jqls(stub).contains(#"project in ("SHOP") AND key in ("SHOP-20", "SHOP-21") AND statusCategory != Done"#))
    }

    @Test(arguments: [(401, JiraError.unauthorized), (403, .unauthorized), (404, .badResponse(404)), (429, .badResponse(429)), (500, .badResponse(500))])
    func statusCodesMapToErrors(status: Int, error: JiraError) async {
        let stub = StubSession { _ in (status, Data()) }
        await #expect(throws: error) { _ = try await JiraClient(config: config, session: stub.session).testConnection() }
    }

    /// A refused connection, stubbed: no test dials a real host.
    @Test func aTransportFailureIsANetworkError() async {
        await #expect {
            _ = try await JiraClient(config: config, session: RefusedURLProtocol.session).testConnection()
        } throws: { error in
            if case JiraError.network = error { return true } else { return false }
        }
    }

    @Test func requestsCarryTheirHeadersAndTheFifteenSecondTimeout() async throws {
        let stub = StubSession { _ in (200, Data(#"{"displayName":"Me"}"#.utf8)) }
        _ = try await JiraClient(config: config, session: stub.session).testConnection()
        let request = try #require(stub.lastRequest)
        #expect(request.url?.absoluteString == "https://example.atlassian.net/rest/api/3/myself")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.timeoutInterval == 15)
    }

    @Test func aConnectionTestNamesTheAccountByDisplayNameThenEmail() async throws {
        let named = StubSession { _ in (200, Data(#"{"displayName":"Me","emailAddress":"me@example.com"}"#.utf8)) }
        #expect(try await JiraClient(config: config, session: named.session).testConnection() == "Me")
        let emailOnly = StubSession { _ in (200, Data(#"{"emailAddress":"me@example.com"}"#.utf8)) }
        #expect(try await JiraClient(config: config, session: emailOnly.session).testConnection() == "me@example.com")
        let neither = StubSession { _ in (200, Data("{}".utf8)) }
        #expect(try await JiraClient(config: config, session: neither.session).testConnection() == "connected")
    }

    /// A body that is not the shape asked for is a decoding error, not an empty result.
    @Test(arguments: [#"[]"#, #"not json"#, #"{"issues":"none"}"#, #"{"issues":[],"extra":1"#])
    func aSearchThatIsNoIssueListIsADecodingError(body: String) async {
        let stub = StubSession { _ in (200, Data(body.utf8)) }
        await #expect(throws: JiraError.decoding) { _ = try await JiraClient(config: config, session: stub.session).myOpenIssues() }
    }

    @Test func aProjectListThatIsNoPageIsADecodingError() async {
        let stub = StubSession { _ in (200, Data(#"{"isLast":true}"#.utf8)) }
        await #expect(throws: JiraError.decoding) { _ = try await JiraClient(config: config, session: stub.session).projects() }
    }

    /// An issue Jira sent without a key or a summary drops alone; what it may omit stays nil, and a
    /// description that is plain text reads as it is.
    @Test func anIssueThatCannotBeReadDropsAloneAndOptionalFieldsMayBeMissing() async throws {
        let body = #"""
        {"issues":[{"key":"A-1","fields":{"summary":"No summary yet"}},
                   {"key":"A-2","fields":{}},
                   {"fields":{"summary":"No key"}},
                   "junk",
                   {"key":"A-3","fields":{"summary":"Plain","description":"Just text","issuetype":"odd","status":{"name":7}}},
                   {"key":"A-4","fields":{"summary":"Empty","description":null}}]}
        """#
        let stub = StubSession { _ in (200, Data(body.utf8)) }
        let tickets = try await JiraClient(config: config, session: stub.session).myOpenIssues()
        #expect(tickets.map(\.key) == ["A-1", "A-3", "A-4"])
        #expect(tickets.map(\.description) == [nil, "Just text", nil])
        #expect(tickets.map(\.issueType) == [nil, nil, nil])
        #expect(tickets.map(\.status) == [nil, nil, nil])
    }

    @Test func aProjectEntryThatCannotBeReadDropsAloneButStillCountsTowardTheNextPage() async throws {
        let stub = StubSession { request in
            let startAt = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "startAt" }?.value
            return (200, Data((startAt == "0"
                ? #"{"values":[{"id":"1","key":"A","name":"Alpha"},{"id":"2"}],"total":3}"#
                : #"{"values":[{"id":"3","key":"C","name":"Gamma"}],"total":3}"#).utf8))
        }
        let projects = try await JiraClient(config: config, session: stub.session).projects()
        #expect(projects.map(\.key) == ["A", "C"])
        #expect(stub.requests.count == 2)
    }

    @Test func malformedPickerResponseIsAnError() async {
        let stub = StubSession { _ in (200, Data(#"{}"#.utf8)) }
        await #expect(throws: JiraError.decoding) {
            _ = try await JiraClient(config: config, session: stub.session).search(text: "SHOP-2")
        }
    }

    /// Ten linked projects mean ten picker requests and ten `key =` lookups; holding them to four
    /// at a time must not lose one, nor reorder what they find.
    @Test func aNumberAcrossManyProjectsStillAsksEveryProjectAndKeepsItsOrder() async throws {
        let projects = (1...10).map { JiraProjectRef(id: "\($0)", key: "P\($0)", name: "Project \($0)", siteURL: config.siteURL) }
        let stub = keyStub(search: { jql in
            jql.contains(#"key = ""#) ? jql.split(separator: "\"").last.map { [String($0)] } : []
        })
        let tickets = try await JiraClient(config: config, session: stub.session).search(text: "7", projects: projects)
        #expect(tickets.map(\.key) == (1...10).map { "P\($0)-7" })
        #expect(Set(pickerQueries(stub)) == Set((1...10).map { "P\($0)-7" }))
        #expect(pickerQueries(stub).count == 10)
        #expect(jqls(stub).filter { $0.contains("key = ") }.count == 10)
    }

    /// The fan-out helper itself: never more than `width` bodies at once, results in item order.
    /// The first `width` bodies wait for each other, so that many really are in flight together
    /// however a loaded runner schedules them.
    @Test func inOrderRunsAtMostWidthAtOnceAndReturnsInItemOrder() async throws {
        let width = 4
        let flight = Flight()
        let results = try await JiraClient.inOrder(Array(0..<20), width: width) { (n: Int) async throws -> Int in
            await flight.enter(latch: n < width ? width : nil)
            try await Task.sleep(for: .milliseconds(1 + (20 - n)))
            await flight.leave()
            return n * 2
        }
        #expect(results == (0..<20).map { $0 * 2 })
        #expect(await flight.peak == width)
    }

    @Test func inOrderThrowsTheFailureOfAnyBody() async {
        await #expect(throws: JiraError.badResponse(500)) {
            _ = try await JiraClient.inOrder(Array(0..<10), width: 3) { (n: Int) async throws -> Int in
                if n == 5 { throw JiraError.badResponse(500) }
                return n
            }
        }
    }

    /// The failure of one body cancels the others and starts no more.
    @Test func inOrderStartsNothingMoreAfterAFailure() async {
        let starts = Locked(0)
        await #expect(throws: JiraError.badResponse(500)) {
            _ = try await JiraClient.inOrder(Array(0..<20), width: 3) { (n: Int) async throws -> Int in
                starts.withLock { $0 += 1 }
                if n == 1 { throw JiraError.badResponse(500) }
                try await Task.sleep(for: .seconds(60))
                return n
            }
        }
        #expect(starts.withLock { $0 } == 3, "the three that started together, and no fourth")
    }

    /// A search dropped for a newer one cancels the task it runs in: the bodies end, none more starts.
    @Test func inOrderEndsWithCancellationWhenItsTaskIsCancelled() async {
        let starts = Locked(0)
        let fanOut = Task {
            try await JiraClient.inOrder(Array(0..<20), width: 3) { (n: Int) async throws -> Int in
                starts.withLock { $0 += 1 }
                try await Task.sleep(for: .seconds(60))
                return n
            }
        }
        await eventually(describing: "three bodies to start") { starts.withLock { $0 } == 3 }
        fanOut.cancel()
        await #expect(throws: CancellationError.self) { _ = try await fanOut.value }
        #expect(starts.withLock { $0 } == 3)
    }

    /// One section that is no section, or a field of the wrong type, costs only itself.
    @Test func anOddPickerSectionCostsOnlyItself() async throws {
        let stub = StubSession { request in
            if request.url?.path == "/rest/api/3/issue/picker" {
                return (200, Data(#"{"sections":["junk",{"id":7,"issues":[{"key":"SHOP-20"}]},{"id":"cs","issues":"none"},{"id":"hs","issues":[{"key":"SHOP-21"},{"key":3}]}]}"#.utf8))
            }
            let found = jqlBody(request)?.contains("key in") == true ? #"[{"key":"SHOP-20","fields":{"summary":"a"}},{"key":"SHOP-21","fields":{"summary":"b"}}]"# : "[]"
            return (200, Data(#"{"issues":\#(found)}"#.utf8))
        }
        let tickets = try await JiraClient(config: config, session: stub.session).search(text: "SHOP-2")
        #expect(tickets.map(\.key) == ["SHOP-20", "SHOP-21"])
    }

    @Test func aPagingFieldOfTheWrongTypeIsReadAsNotSent() async throws {
        let stub = StubSession { _ in (200, Data(#"{"values":[{"id":"1","key":"A","name":"Alpha"}],"isLast":"yes","total":"many"}"#.utf8)) }
        let projects = try await JiraClient(config: config, session: stub.session).projects()
        #expect(projects.map(\.key) == ["A"])
        #expect(stub.requests.count == 1, "no usable paging field and a short page is the last page")
    }

    @Test func anAccountNameOfTheWrongTypeFallsBackToTheNextOne() async throws {
        let stub = StubSession { _ in (200, Data(#"{"displayName":5,"emailAddress":"me@example.com"}"#.utf8)) }
        #expect(try await JiraClient(config: config, session: stub.session).testConnection() == "me@example.com")
        let neither = StubSession { _ in (200, Data(#"{"displayName":[],"emailAddress":null}"#.utf8)) }
        #expect(try await JiraClient(config: config, session: neither.session).testConnection() == "connected")
    }

    var app: JiraProjectRef { JiraProjectRef(id: "1", key: "SHOP", name: "Storefront", siteURL: config.siteURL) }
    var ops: JiraProjectRef { JiraProjectRef(id: "2", key: "PAY", name: "Payments", siteURL: config.siteURL) }

    /// Answers the picker with `picker[query]` as Current Search and `history[query]` as History,
    /// and a JQL search with a ticket per key `search` returns for it — nil answers HTTP 400.
    private func keyStub(picker: [String: [String]] = [:], history: [String: [String]] = [:],
                         search: @escaping @Sendable (String) -> [String]? = { _ in [] }) -> StubSession {
        StubSession { request in
            if request.url?.path == "/rest/api/3/issue/picker" {
                let query = pickerValue("query", of: request) ?? ""
                let sections = [("cs", picker[query] ?? []), ("hs", history[query] ?? [])].map { id, keys in
                    ["id": id, "issues": keys.map { ["key": $0] }] as [String: Any]
                }
                return (200, try! JSONSerialization.data(withJSONObject: ["sections": sections]))
            }
            guard let keys = search(jqlBody(request) ?? "") else { return (400, Data()) }
            let issues = keys.map { ["key": $0, "fields": ["summary": "Summary of \($0)"]] }
            return (200, try! JSONSerialization.data(withJSONObject: ["issues": issues]))
        }
    }

    private func pickerQueries(_ stub: StubSession) -> [String] {
        stub.requests.compactMap { pickerValue("query", of: $0) }
    }

    private func jqls(_ stub: StubSession) -> [String] { stub.requests.compactMap(jqlBody) }

    private func pickerParameter(_ name: String, _ stub: StubSession) -> String? {
        stub.lastRequest.flatMap { pickerValue(name, of: $0) }
    }

    private func jql(_ stub: StubSession) -> String? { stub.lastRequest.flatMap(jqlBody) }
}

private func pickerValue(_ name: String, of request: URLRequest) -> String? {
    guard let url = request.url, url.path == "/rest/api/3/issue/picker" else { return nil }
    return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
}

private func jqlBody(_ request: URLRequest) -> String? {
    (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])?["jql"] as? String
}

/// Counts the bodies of a fan-out that are inside it, and holds the first few until all have entered.
private actor Flight {
    private(set) var peak = 0
    private var now = 0, entered = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func enter(latch: Int?) async {
        now += 1; peak = max(peak, now); entered += 1
        guard let latch else { return }
        if entered >= latch {
            waiting.forEach { $0.resume() }
            waiting = []
        } else {
            await withCheckedContinuation { waiting.append($0) }
        }
    }

    func leave() { now -= 1 }
}
