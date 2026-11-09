import Foundation
import Testing
@testable import ShellforgeCore

@Suite struct FeedbackSubmissionTests {
    let versions = AppVersions(version: "0.8.0", macOS: "26.1.0")

    @Test func whitespaceOnlyTextIsOmittedFromTheJSON() throws {
        let s = FeedbackSubmission(versions: versions, good: "  ", bad: "slow", rating: nil)
        let data = try JSONEncoder().encode(s)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["good"] == nil)
        #expect(Set(object.keys).isSubset(of: ["version", "macos", "rating", "good", "bad"]))
        #expect(object["bad"] as? String == "slow")
        #expect(object["version"] as? String == "0.8.0")
        #expect(object["macos"] as? String == "26.1.0")
    }

    @Test func aRatingAloneIsNotText() {
        #expect(!FeedbackSubmission(versions: versions, good: "", bad: " \n", rating: 4).hasText)
        #expect(FeedbackSubmission(versions: versions, good: "x", bad: "", rating: nil).hasText)
    }

    @Test func invisibleOnlyTextCountsAsBlank() {
        let invisible = "\u{0}\u{7}\u{200B}\u{200C}\u{200D}\u{2060}\u{FEFF}\u{200E}\u{200F}\u{202A}\u{202E}\u{2066}\u{2069} \n\t"
        let blank = FeedbackSubmission(versions: versions, good: invisible, bad: "\u{200B}", rating: 3)
        #expect(!blank.hasText)
        #expect(blank.good == nil && blank.bad == nil)
        #expect(FeedbackSubmission(versions: versions, good: "\u{200B}a\u{200B}", bad: "", rating: nil).hasText)
    }

    @Test func plainTextWithEveryField() {
        let s = FeedbackSubmission(versions: versions, good: "fast", bad: "crashes", rating: 4)
        #expect(s.plainText == """
            What’s working well?
            fast

            What’s missing, or gets in your way?
            crashes

            Rating: 4/5

            Shellforge 0.8.0, macOS 26.1.0
            """)
    }

    @Test func plainTextLeavesOutAbsentSections() {
        let s = FeedbackSubmission(versions: versions, good: "", bad: "crashes", rating: nil)
        #expect(s.plainText == """
            What’s missing, or gets in your way?
            crashes

            Shellforge 0.8.0, macOS 26.1.0
            """)
    }
}
