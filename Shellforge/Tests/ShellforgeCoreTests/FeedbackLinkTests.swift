import Foundation
import Testing
@testable import ShellforgeCore

@Suite struct FeedbackLinkTests {
    let versions = AppVersions(version: "0.8.0", macOS: "26.1.0")

    private func items(_ url: URL) -> [String: String] {
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: q.map { ($0.name, $0.value ?? "") })
    }

    @Test func formFillsEveryField() {
        let s = FeedbackSubmission(versions: versions, good: "fast", bad: "crashes", rating: 4)
        let result = FeedbackLink.form(s)
        let q = items(result.url)
        #expect(q["template"] == "feedback.yml")
        #expect(q["version"] == "0.8.0")
        #expect(q["macos"] == "26.1.0")
        #expect(q["rating"] == "4/5")
        #expect(q["good"] == "fast")
        #expect(q["bad"] == "crashes")
        #expect(!result.cut)
    }

    @Test func aFieldOverMaxDetailsIsCutWithTheNote() {
        let s = FeedbackSubmission(versions: versions, good: String(repeating: "a", count: BugReportLink.maxDetails + 5),
                                   bad: "", rating: nil)
        let result = FeedbackLink.form(s)
        #expect(result.cut)
        #expect(items(result.url)["good"]?.hasSuffix(BugReportLink.truncationNote) == true)
    }

    @Test func longNonASCIIStaysUnderTheCap() {
        let s = FeedbackSubmission(versions: versions, good: String(repeating: "é", count: 2000),
                                   bad: String(repeating: "😀", count: 2000), rating: 5)
        let result = FeedbackLink.form(s)
        #expect(result.url.absoluteString.utf8.count <= FeedbackLink.maxURLLength)
        #expect(result.cut)
        let q = items(result.url)
        #expect(q["good"]?.hasSuffix(BugReportLink.truncationNote) == true)
        #expect(q["bad"]?.hasSuffix(BugReportLink.truncationNote) == true)
    }

    @Test func issueLink() {
        #expect(FeedbackLink.issue(42).absoluteString == "https://github.com/NathanGel/shellforge/issues/42")
    }
}
