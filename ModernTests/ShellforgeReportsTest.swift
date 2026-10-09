//
//  ShellforgeReportsTest.swift
//  Shellforge
//
//  Shellforge reads each session's variables by the names in ShellforgeCore's
//  `SessionReport.Variable`; these are iTerm2's names for them. (ModernTests cannot link
//  ShellforgeCore's symbols, so the names are compared as written.)
//

import XCTest
@testable import iTerm2SharedARC

final class ShellforgeReportsTest: XCTestCase {
    func testITerm2NamesTheVariablesAsShellforgeReadsThem() {
        XCTAssertEqual(iTermVariableKeySessionCommandLine, "commandLine")
        XCTAssertEqual(iTermVariableKeySessionJobPid, "jobPid")
        XCTAssertEqual(iTermVariableKeySessionAutoName, "autoName")
        XCTAssertEqual(iTermVariableKeySessionPath, "path")
    }
}
