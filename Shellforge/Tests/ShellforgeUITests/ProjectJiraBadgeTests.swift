// Ported from AiTerm (app/Tests/AiTermTests/ProjectJiraBadgeTests.swift and BadgeDetailsTests.swift), GPLv3, Laurens D'Hondt.
import Foundation
import Testing
import ShellforgeCore
@testable import ShellforgeUI

/// The rule a project row follows: the first linked Jira project's key, opening it, and — when it
/// links more — a `+n` after it that offers every one of them in a menu, in the order they were
/// linked; linked to none, it wears nothing. And a task row's ticket: its key, opening it. The
/// badges' own pixels belong to `Badge`; what is tested here is only what they say and where they
/// point.
@Suite struct ProjectJiraBadgeTests {
    private static let site = URL(string: "https://example.atlassian.net")!
    private static let frontend = JiraProjectRef(id: "10001", key: "SHOP", name: "Storefront", siteURL: site)
    private static let portal = JiraProjectRef(id: "10002", key: "PAY", name: "Payments", siteURL: site)
    private static let web = JiraProjectRef(id: "10003", key: "WEB", name: "Website", siteURL: site)

    private func project(jira: [JiraProjectRef]) -> Project {
        Project(name: "Shellforge", path: "/tmp/shellforge", jiraProjects: jira)
    }

    @Test func anUnlinkedProjectWearsNoBadge() {
        #expect(ProjectJiraBadge.badge(for: project(jira: [])) == nil)
    }

    @Test func aProjectLinkedToOneWearsItsKeyAndOpensIt() throws {
        let badge = try #require(ProjectJiraBadge.badge(for: project(jira: [Self.frontend])))
        #expect(badge.label == "SHOP")
        #expect(badge.url == URL(string: "https://example.atlassian.net/browse/SHOP")!)
        // The key is all the row shows, so the project's name only reaches the reader on hover.
        #expect(badge.help == "Storefront — https://example.atlassian.net/browse/SHOP")
        #expect(badge.overflow == nil)
    }

    @Test func aProjectLinkedToSeveralWearsTheFirstKeyThenTheRestBehindAPlusN() throws {
        let badge = try #require(ProjectJiraBadge.badge(for: project(jira: [Self.frontend, Self.portal, Self.web])))
        // The first linked project is a badge of its own, as if it were the only one.
        #expect(badge.label == "SHOP")
        #expect(badge.url == URL(string: "https://example.atlassian.net/browse/SHOP")!)
        let overflow = try #require(badge.overflow)
        #expect(overflow.label == "+2")
        // The menu offers every project, the first included, so it is the whole list in one place.
        #expect(overflow.items == [
            .init(title: "SHOP — Storefront", url: URL(string: "https://example.atlassian.net/browse/SHOP")!),
            .init(title: "PAY — Payments", url: URL(string: "https://example.atlassian.net/browse/PAY")!),
            .init(title: "WEB — Website", url: URL(string: "https://example.atlassian.net/browse/WEB")!),
        ])
        // A count says nothing on its own: the hover names every project, and VoiceOver the rest.
        #expect(overflow.help == "Jira · SHOP Storefront · PAY Payments · WEB Website")
        #expect(overflow.accessibilityLabel == "2 more Jira projects: PAY and WEB")
    }

    @Test func oneMoreProjectIsReadInTheSingular() throws {
        let badge = try #require(ProjectJiraBadge.badge(for: project(jira: [Self.frontend, Self.portal])))
        #expect(badge.overflow?.label == "+1")
        #expect(badge.overflow?.accessibilityLabel == "1 more Jira project: PAY")
    }

    @Test func turningTheProjectKeyOffLeavesTheMarkAndThePlusN() throws {
        // The switch drops the key; the +n is not a key, and without it the mark could not say there
        // is more behind it.
        let badge = try #require(ProjectJiraBadge.badge(for: project(jira: [Self.frontend, Self.portal]), showsKey: false))
        #expect(badge.label == nil)
        #expect(badge.help == "Storefront (SHOP) — https://example.atlassian.net/browse/SHOP")
        #expect(badge.overflow?.label == "+1")
    }

    // -- a task's ticket (BadgeDetailsTests) ---------------------------------------------

    @Test func aTaskWearsItsTicketsKeyAndOpensIt() {
        let ticket = JiraRef(key: "SHOP-12", summary: "Checkout", url: "https://j/SHOP-12")
        #expect(TaskTicketBadge(jira: ticket) == .init(label: "SHOP-12", help: "https://j/SHOP-12", url: "https://j/SHOP-12"))
        #expect(TaskTicketBadge(jira: ticket, showsKey: false) == .init(label: nil, help: "SHOP-12 — https://j/SHOP-12", url: "https://j/SHOP-12"))
    }

    @Test func aTicketWithoutALinkStillNamesItsKeyOnHover() {
        let ticket = JiraRef(key: "SHOP-12", summary: "Checkout", url: "")
        #expect(TaskTicketBadge(jira: ticket, showsKey: false) == .init(label: nil, help: "SHOP-12", url: nil))
        #expect(TaskTicketBadge(jira: ticket) == .init(label: "SHOP-12", help: "SHOP-12", url: nil))
    }

    @Test func aTaskWithoutATicketWearsNone() {
        #expect(TaskTicketBadge(jira: nil) == nil)
    }
}
