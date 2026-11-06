//
//  ShellforgeFeedbackTest.swift
//  ModernTests
//
//  Help › Send Feedback… exists, and the bug form takes its versions from the one shared place.
//

import ShellforgeCore
import XCTest
@testable import iTerm2SharedARC

final class ShellforgeFeedbackTest: XCTestCase {
    @MainActor
    func testHelpMenuOffersSendFeedback() throws {
        let item = try XCTUnwrap(NSApp.helpMenu?.items.first { $0.title == "Send Feedback…" })
        XCTAssertEqual(item.action, NSSelectorFromString("shellforgeSendFeedback:"))
    }

    func testBugReportUsesTheSharedVersions() throws {
        let url = iTermShellforgeBugReport.formURL(title: nil, details: nil)
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let versions = AppVersions.current
        XCTAssertEqual(parts.queryItems?.first { $0.name == "version" }?.value, versions.version)
        XCTAssertEqual(parts.queryItems?.first { $0.name == "macos" }?.value, versions.macOS)
    }
}
