//
//  ShellforgeHostTest.swift
//  Shellforge
//
//  A task's tab runs the user's login shell in the task's worktree, whatever the default
//  profile says about its command or directory.
//

import ShellforgeCore
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

    /// Each of Shellforge's ⌃⌘ keys (the Tasks menu, Hide Sidebar and the panels) is in the main menu once:
    /// none shadows an iTerm2 shortcut, and none is shadowed.
    func testShellforgesControlCommandKeysAreTheirsAlone() {
        guard let main = NSApp.mainMenu else { return XCTFail("no main menu") }
        func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) } }
        let all = items(main)
        for key in ["n", "r", "t", "p", "g", "]", "[", "\u{8}", "a", "l", "s", "e", "m", "i", "h"] {
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

    /// Sparkle asks its delegate before every check, scheduled or chosen, and is always refused:
    /// iTerm2's builds are never offered. Outside tests that delegate is the app delegate; a test
    /// host hands Sparkle iTermTestHostIsolation's instead, so both must refuse.
    func testSparkleIsNeverAllowedToCheck() throws {
        let appDelegate = try XCTUnwrap(NSApp.delegate as? NSObject)
        let updaterClass = try XCTUnwrap(NSClassFromString("SUUpdater") as? NSObject.Type)
        let updater = try XCTUnwrap(updaterClass.perform(NSSelectorFromString("sharedUpdater"))?.takeUnretainedValue() as? NSObject)
        let sparkleDelegate = try XCTUnwrap(updater.value(forKey: "delegate") as? NSObject, "Sparkle has a delegate")
        XCTAssertTrue(sparkleDelegate === TestHostIsolation.updaterDelegate, "a test host's Sparkle delegate is the isolation delegate")
        let ask = NSSelectorFromString("updaterMayCheckForUpdates:")
        typealias May = @convention(c) (AnyObject, Selector, AnyObject?) -> ObjCBool
        for delegate in [appDelegate, sparkleDelegate] {
            XCTAssertTrue(delegate.responds(to: ask), "\(type(of: delegate))")
            let may = unsafeBitCast(delegate.method(for: ask), to: May.self)
            XCTAssertFalse(may(delegate, ask, updater).boolValue, "\(type(of: delegate))")
        }
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

    /// A panel's tab carries its tag in a user variable, as `openTab(in:title:command:panel:)`'s
    /// `didMakeSession` sets it, and `tabs` reads it back from any of its panes, the focused first.
    @MainActor func testAPanelTabIsTaggedAndRead() throws {
        let tagged = try XCTUnwrap(PTYSession(synthetic: true))
        let split = try XCTUnwrap(PTYSession(synthetic: true))
        let file = PanelTab.file(project: UUID(), path: "src/app.ts")
        iTermShellforgeHost.tag(tagged, panel: file)
        XCTAssertEqual(tagged.genericScope.value(forVariableName: ShellforgeTags.panel) as? String, file.tagValue)
        XCTAssertEqual(iTermShellforgeHost.panel(ofPanes: [tagged]), file)
        XCTAssertEqual(iTermShellforgeHost.panel(ofPanes: [split, tagged]), file, "a split focused beside it keeps the tag")
        XCTAssertNil(iTermShellforgeHost.panel(ofPanes: [split]))
        iTermShellforgeHost.tag(split, panel: .ssh(alias: "staging"))
        XCTAssertEqual(iTermShellforgeHost.panel(ofPanes: [split, tagged]), .ssh(alias: "staging"), "the focused pane first")
    }

    /// The tag is saved with the session's arrangement, among the user variables iTerm2 restores
    /// at relaunch as it restores a task's tag. Restoring a session needs a whole window, which a
    /// unit test cannot drive; only the saving half is checked here.
    @MainActor func testAPanelTagIsSavedWithTheArrangement() throws {
        let session = try XCTUnwrap(PTYSession(synthetic: true))
        iTermShellforgeHost.tag(session, panel: .ssh(alias: "staging"))
        let saved = session.encodableArrangementVariables()
        let user = saved["user"] as? [AnyHashable: Any]
        XCTAssertEqual((user?["shellforge_panel"] ?? saved[ShellforgeTags.panel]) as? String, "ssh:staging", "\(saved)")
    }

    /// A pane split off a panel's tab takes the panel's tag, so the tab stays the host's when the
    /// pane it was opened in closes first; a pane with a tag of its own keeps it.
    @MainActor func testASplitPaneKeepsItsPanelTabsOwner() throws {
        let original = try XCTUnwrap(PTYSession(synthetic: true))
        let split = try XCTUnwrap(PTYSession(synthetic: true))
        iTermShellforgeHost.tag(original, panel: .ssh(alias: "staging"))
        iTermShellforgeHost.join([original, split])
        XCTAssertEqual(split.genericScope.value(forVariableName: ShellforgeTags.panel) as? String, "ssh:staging")
        XCTAssertEqual(iTermShellforgeHost.panel(ofPanes: [split]), .ssh(alias: "staging"), "the original pane closed")
        let other = try XCTUnwrap(PTYSession(synthetic: true))
        iTermShellforgeHost.tag(other, panel: .ssh(alias: "db-tunnel"))
        iTermShellforgeHost.join([original, other])
        XCTAssertEqual(iTermShellforgeHost.panel(ofPanes: [other]), .ssh(alias: "db-tunnel"))
    }
}
