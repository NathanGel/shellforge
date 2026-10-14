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

    /// The agent's initial text is one-shot: PTYSession clears it from the session once read, so a
    /// ⌘D split or a ⌘T tab, which copy the session's profile, start a plain shell.
    func testATaskTabsInitialTextIsOneShot() {
        let profile = iTermShellforgeSidebar.taskTabProfile(base: [:], directory: "/tmp/x", initialText: " claude")
        XCTAssertEqual(profile[iTermShellforgeSidebar.initialTextOnceKey] as? Bool, true)
        let plain = iTermShellforgeSidebar.taskTabProfile(base: [:], directory: "/tmp/x")
        XCTAssertNil(plain[iTermShellforgeSidebar.initialTextOnceKey])
        XCTAssertEqual(iTermShellforgeSidebar.initialTextOnceKey, "Shellforge Initial Text Once", "PTYSession.m reads this key")
    }

    /// The agent's command reaches the tab as its initial text, exactly as handed over — the
    /// backslashes `TabCommand.initialText` doubled stay doubled for iTerm2's evaluator to undo.
    func testTheInitialTextIsSentWithItsBackslashes() {
        let profile = iTermShellforgeSidebar.taskTabProfile(base: [:], directory: "/tmp/x", initialText: #" claude 'a \\(b)'"#)
        XCTAssertEqual(profile[KEY_INITIAL_TEXT] as? String, #" claude 'a \\(b)'"#)
        XCTAssertEqual(profile[KEY_WORKING_DIRECTORY] as? String, "/tmp/x")
    }

    /// A reopened task's tab is a shell: no initial text is added.
    func testAShellTabHasNoInitialTextOfItsOwn() {
        let profile = iTermShellforgeSidebar.taskTabProfile(base: [:], directory: "/tmp/x", initialText: nil)
        XCTAssertNil(profile[KEY_INITIAL_TEXT])
    }

    /// ⌘B is Backpack Mode's alone in the main menu: iTerm2's own B shortcuts all carry another
    /// modifier.
    func testCommandBIsFreeInTheMainMenu() {
        guard let main = NSApp.mainMenu else { return XCTFail("no main menu") }
        func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) } }
        let commandB = items(main).filter { $0.keyEquivalent == "b" && $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == [.command] }
        XCTAssertEqual(commandB.map(\.title), ["Backpack Mode"])
    }

    /// Each of Shellforge's ⌃⌘ keys (the Tasks menu and Hide Sidebar) is in the main menu once:
    /// none shadows an iTerm2 shortcut, and none is shadowed.
    func testShellforgesControlCommandKeysAreTheirsAlone() {
        guard let main = NSApp.mainMenu else { return XCTFail("no main menu") }
        func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) } }
        let all = items(main)
        for key in ["n", "r", "t", "p", "g", "]", "[", "\u{8}", "a", "l", "s"] {
            let users = all.filter {
                $0.keyEquivalent == key && $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == [.control, .command]
            }
            XCTAssertEqual(users.count, 1, "⌃⌘\(key) is used by \(users.map(\.title))")
        }
    }

    /// Backpack Mode's keys are this Mac's state, never a shared setting: iTerm2's "load settings
    /// from a custom folder" clears syncable keys at launch, before Backpack's crash recovery reads
    /// `backpack.engaged`, and would carry a Mac's engaged flag and hotspot to every other Mac.
    func testBackpackStateNeverSyncsWithSettings() {
        let prefs = iTermRemotePreferences.sharedInstance()
        XCTAssertFalse(prefs.preferenceKeyIsSyncable("backpack.engaged"))
        XCTAssertFalse(prefs.preferenceKeyIsSyncable("backpack.network"))
        XCTAssertTrue(prefs.preferenceKeyIsSyncable("Columns"), "an ordinary setting still syncs")
    }

    /// The built app names Shellforge's own feed, and a Development build marks itself as one, so
    /// it never replaces itself with a release. Sparkle has no feed of iTerm2's to read.
    func testTheBundleCarriesShellforgesFeedAndTheDevMark() {
        let info = Bundle.main
        XCTAssertEqual(info.object(forInfoDictionaryKey: "ShellforgeUpdateFeed") as? String, "github:NathanGel/shellforge")
        XCTAssertEqual(info.object(forInfoDictionaryKey: "ShellforgeDevBuild") as? String, "YES", "the Development configuration sets SHELLFORGE_DEV_BUILD")
        XCTAssertNil(info.object(forInfoDictionaryKey: "SUFeedURL"))
        XCTAssertEqual(info.object(forInfoDictionaryKey: "SUEnableAutomaticChecks") as? Bool, false)
    }

    /// Sparkle asks the app delegate before every check, scheduled or chosen, and is always refused:
    /// iTerm2's builds are never offered.
    func testSparkleIsNeverAllowedToCheck() throws {
        let delegate = try XCTUnwrap(NSApp.delegate as? NSObject)
        let updaterClass = try XCTUnwrap(NSClassFromString("SUUpdater") as? NSObject.Type)
        let updater = try XCTUnwrap(updaterClass.perform(NSSelectorFromString("sharedUpdater"))?.takeUnretainedValue() as? NSObject)
        XCTAssertTrue(updater.value(forKey: "delegate") as? NSObject === delegate, "Sparkle's delegate is the app delegate")
        let ask = NSSelectorFromString("updaterMayCheckForUpdates:")
        XCTAssertTrue(delegate.responds(to: ask))
        typealias May = @convention(c) (AnyObject, Selector, AnyObject?) -> ObjCBool
        let may = unsafeBitCast(delegate.method(for: ask), to: May.self)
        XCTAssertFalse(may(delegate, ask, updater).boolValue)
    }

    /// Check for Updates… is in the app menu once, and its action reaches Shellforge's controller,
    /// which is idle until it is chosen.
    @MainActor func testCheckForUpdatesIsShellforgesOwn() throws {
        guard let main = NSApp.mainMenu else { return XCTFail("no main menu") }
        func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) } }
        let check = items(main).filter { $0.action == NSSelectorFromString("checkForUpdatesFromMenu:") }
        XCTAssertEqual(check.map(\.title), ["Check for Updates…"])
        let delegate = try XCTUnwrap(NSApp.delegate as? NSMenuItemValidation)
        XCTAssertTrue(delegate.validateMenuItem(try XCTUnwrap(check.first)), "enabled while no check runs")
        XCTAssertFalse(iTermShellforgeUpdates.isBusy())
    }
}
