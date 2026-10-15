//
//  ShellforgeBugReportTest.swift
//  ModernTests
//
//  Every "report a bug" in the app reaches Shellforge's own GitHub forms, never iTerm2's tracker.
//

import XCTest
@testable import iTerm2SharedARC

final class ShellforgeBugReportTest: XCTestCase {
    private let chooser = "https://github.com/NathanGel/shellforge/issues/new/choose"

    func testTheFormCarriesThisBuildsVersion() throws {
        let url = iTermShellforgeBugReport.formURL(title: "Crash", details: nil)
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.host, "github.com")
        XCTAssertEqual(parts.path, "/NathanGel/shellforge/issues/new")
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        XCTAssertEqual(parts.queryItems?.first { $0.name == "version" }?.value, version)
        XCTAssertEqual(parts.queryItems?.first { $0.name == "title" }?.value, "[Bug] Crash")
    }

    func testTheChooserIsShellforges() {
        XCTAssertEqual(iTermShellforgeBugReport.chooserURLString, chooser)
    }

    /// The messages that print a link say Shellforge's, in every language the app ships.
    func testTranslatedMessagesNameShellforgesForms() throws {
        let bundle = Bundle(for: iTermShellforgeBugReport.self)
        let keys = ["AppSignature.CorruptButValidSignature", "CorruptApplication.SignatureValidUnexpected",
                    "DependencyEditor.UpgradeErrorMessage", "ImportExport.BugEncountered"]
        let languages = bundle.localizations.filter { $0 != "Base" }
        XCTAssertFalse(languages.isEmpty)
        var checked = 0
        for language in languages {
            let path = try XCTUnwrap(bundle.path(forResource: language, ofType: "lproj"), language)
            let localized = try XCTUnwrap(Bundle(path: path))
            for key in keys {
                let text = localized.localizedString(forKey: key, value: "missing", table: "Localizable")
                guard text != "missing" else { continue }
                checked += 1
                XCTAssertTrue(text.contains(chooser), "\(language) \(key): \(text)")
                XCTAssertFalse(text.contains("iterm2.com/bugs"), "\(language) \(key)")
            }
        }
        XCTAssertGreaterThanOrEqual(checked, keys.count * 2, "the messages were found in at least two languages")
        print("checked \(checked) messages in \(languages.count) languages")
    }
}
