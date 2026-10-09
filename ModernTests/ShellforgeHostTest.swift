//
//  ShellforgeHostTest.swift
//  Shellforge
//
//  A task's tab runs the user's login shell in the task's worktree, whatever the default
//  profile says about its command or directory.
//

import XCTest
@testable import iTerm2SharedARC

final class ShellforgeHostTest: XCTestCase {
    func testATaskTabRunsTheLoginShellInTheWorktree() {
        let base: [AnyHashable: Any] = [KEY_CUSTOM_COMMAND: "Yes", KEY_COMMAND_LINE: "/usr/bin/top",
                                        KEY_CUSTOM_DIRECTORY: "No", KEY_NAME: "Default"]
        let profile = iTermShellforgeSidebar.taskTabProfile(base: base, directory: "/r/aiterm/.worktrees/fix-login")
        XCTAssertEqual(profile[KEY_CUSTOM_COMMAND] as? String, "No")
        XCTAssertEqual(profile[KEY_CUSTOM_DIRECTORY] as? String, kProfilePreferenceInitialDirectoryCustomValue)
        XCTAssertEqual(profile[KEY_WORKING_DIRECTORY] as? String, "/r/aiterm/.worktrees/fix-login")
        XCTAssertEqual(profile[KEY_NAME] as? String, "Default")
    }
}
