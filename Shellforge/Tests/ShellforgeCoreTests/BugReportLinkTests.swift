import Foundation
import Testing
@testable import ShellforgeCore

@Suite struct BugReportLinkTests {
    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    /// Text that can only print a link names the forms' chooser on Shellforge's GitHub, never iTerm2's.
    @Test func theChooserIsShellforgesOwn() {
        #expect(BugReportLink.chooser == "https://github.com/NathanGel/shellforge/issues/new/choose")
    }

    /// The bug-report form opens with what is known already filled in, field by field.
    @Test func theFormIsFilledIn() throws {
        let url = BugReportLink.form(version: "0.4.0", macOS: "26.1", title: "Usage unavailable", details: "the log")
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(parts.host == "github.com" && parts.path == "/NathanGel/shellforge/issues/new")
        #expect(query(url) == ["template": "bug-report.yml", "version": "0.4.0", "macos": "26.1",
                               "title": "[Bug] Usage unavailable", "actual": "the log"])
    }

    /// Nothing known yet: the bare form, with the version and macOS the reporter would look up.
    @Test func aBareFormKeepsItsOwnTitle() {
        let fields = query(BugReportLink.form(version: "0.4.0", macOS: "26.1", title: nil, details: nil))
        #expect(fields == ["template": "bug-report.yml", "version": "0.4.0", "macos": "26.1"])
    }

    /// A long report is cut to fit a link and says where the rest is.
    @Test func longDetailsAreCutAndSaySo() throws {
        let long = String(repeating: "x", count: BugReportLink.maxDetails + 500)
        let actual = try #require(query(BugReportLink.form(version: "1", macOS: "1", title: nil, details: long))["actual"])
        #expect(actual.hasPrefix(String(repeating: "x", count: BugReportLink.maxDetails)))
        #expect(actual.hasSuffix(BugReportLink.truncationNote))
        #expect(actual.count == BugReportLink.maxDetails + BugReportLink.truncationNote.count)
    }
}
