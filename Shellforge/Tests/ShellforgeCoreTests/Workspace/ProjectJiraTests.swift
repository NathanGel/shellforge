// Ported from AiTerm (app/Tests/AiTermCoreTests/ModelsTests.swift), GPLv3, Laurens D'Hondt.
import Foundation
import Testing
@testable import ShellforgeCore

/// What a project links, as the workspace file keeps it.
@Suite struct ProjectJiraTests {
    static let site = URL(string: "https://example.atlassian.net")!
    static let shop = JiraProjectRef(id: "10001", key: "SHOP", name: "Storefront", siteURL: site)
    static let pay = JiraProjectRef(id: "10002", key: "PAY", name: "Payments", siteURL: site)

    @Test func aProjectFromAnOlderWorkspaceLinksNoJiraProject() throws {
        let json = #"{"id":"1EB4C0DE-0000-0000-0000-000000000001","name":"Repo","path":"/repo","addedAt":1,"collapsed":false}"#
        let project = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        #expect(project.jiraProjects.isEmpty)
    }

    @Test func linkedJiraProjectsRoundTripInOrder() throws {
        let project = Project(name: "Repo", path: "/repo", jiraProjects: [Self.pay, Self.shop])
        let back = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        #expect(back.jiraProjects == [Self.pay, Self.shop])
        #expect(back == project)
    }

    @Test func linkedJiraProjectsReadAsTheirKeysInOrder() {
        #expect([Self.shop].keyList == "SHOP")
        #expect([Self.shop, Self.pay].keyList == "SHOP and PAY")
    }
}
