// Ported from AiTerm (app/Tests/AiTermCoreTests/JiraProjectSearchTests.swift), GPLv3, Laurens D'Hondt.
import Testing
import Foundation
@testable import ShellforgeCore

@Suite struct JiraProjectSearchTests {
    let site = URL(string: "https://example.atlassian.net")!

    private func project(_ key: String, _ name: String) -> JiraProjectRef {
        JiraProjectRef(id: key, key: key, name: name, siteURL: site)
    }

    @Test func testAProjectLinksToItsOwnBrowsePageOnItsOwnSite() {
        #expect(project("SHOP", "Storefront").browseURL.absoluteString == "https://example.atlassian.net/browse/SHOP")
    }

    @Test func testAnEmptyQueryKeepsJirasOwnOrder() {
        let all = [project("SHOP", "Storefront"), project("WEB", "Website")]
        #expect(JiraProjectSearch.rank(all, query: "  ") == all)
    }

    /// The sheet adds to what is linked, so a linked project is not offered a second time.
    @Test func testAlreadyLinkedProjectsAreLeftOut() {
        let all = [project("SHOP", "Storefront"), project("PAY", "Payments"), project("WEB", "Website")]
        #expect(JiraProjectSearch.rank(all, query: "", excluding: [all[0]]) == [all[1], all[2]])
        #expect(JiraProjectSearch.rank(all, query: "t", excluding: [all[1]]) == [all[0], all[2]])
    }

    @Test func testAKeyPrefixOutranksANamePrefix() {
        let key = project("SHOP", "Platform")
        let name = project("PLT", "Shopping flags")
        #expect(JiraProjectSearch.rank([name, key], query: "shop") == [key, name])
    }

    @Test func testANamePrefixOutranksAMatchInTheMiddleOfAName() {
        let prefix = project("AAA", "Service desk")
        let middle = project("BBB", "Customer service")
        #expect(JiraProjectSearch.rank([middle, prefix], query: "service") == [prefix, middle])
    }

    @Test func testProjectsMatchingNeitherKeyNorNameAreDropped() {
        let all = [project("SHOP", "Storefront"), project("WEB", "Website")]
        #expect(JiraProjectSearch.rank(all, query: "billing").isEmpty)
    }

    @Test func testTwoProjectsInTheSameTierKeepJirasOrder() {
        let all = [project("WEB", "Website"), project("WEBX", "Website extras")]
        #expect(JiraProjectSearch.rank(all, query: "web") == all)
    }
}
