// Ported from AiTerm (app/Sources/AiTerm/ExternalApps.swift), GPLv3, Laurens D'Hondt.
import Foundation
import Testing
@testable import ShellforgeUI

/// A badge opens only a web page: the links come from the workspace file and Jira's answers, and a
/// `file:` or custom-scheme URL in either must not launch whatever handles it.
@Suite struct ExternalLinkTests {
    @Test func onlyWebLinksOpen() {
        #expect(ExternalLink.webURL("https://example.atlassian.net/browse/SHOP-1") == URL(string: "https://example.atlassian.net/browse/SHOP-1"))
        #expect(ExternalLink.webURL("HTTP://example.com") != nil)
        #expect(ExternalLink.webURL("file:///etc/passwd") == nil)
        #expect(ExternalLink.webURL("javascript:alert(1)") == nil)
        #expect(ExternalLink.webURL("x-terminal://run") == nil)
        #expect(ExternalLink.webURL("") == nil)
        #expect(ExternalLink.webURL(nil) == nil)
    }
}
