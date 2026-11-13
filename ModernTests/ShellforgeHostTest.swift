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

    /// What iTerm2 does to a custom command line before it runs it: evaluate it as an interpolated
    /// string (`ITAddressBookMgr computeCommandForProfile`), ask for any `$$NAME$$` and turn `$$$$`
    /// into `$$` (`iTermSessionFactory`), then split it (`PTYSession computeArgvForCommand`).
    private func argvITerm2Runs(_ commandLine: String) -> [String]? {
        var value: String?
        let evaluator = iTermExpressionEvaluator(strictInterpolatedString: commandLine, scope: iTermVariableScope())
        evaluator.evaluate(withTimeout: 0, sideEffectsAllowed: true) { value = $0.value as? String }
        guard let evaluated = value?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let asked = (evaluated as NSString).doubleDollarVariables() as? Set<String> ?? []
        XCTAssertTrue(asked.isSubset(of: ["$$$$"]), "iTerm2 would ask for \(asked)")
        let substituted = (evaluated as NSString).performingSubstitutions(["$$$$": "$$"])
        return (substituted as NSString).componentsInShellCommand()
    }

    /// A file's tab runs `[shell, -l, -i, -c, script, shellforge-open, path]` exactly, for the
    /// review's hostile names: a Meta byte, an option to vim, quotes, iTerm2's own `\(…)`, `$$…$$`
    /// and `$$$$`, odd spaces, a quote with a combining mark.
    func testAFileTabsCommandLineParsesBackToItsArgv() throws {
        let hostile = ["ň$(touch PWNED);#", "\u{85}$(touch PWNED);#", "\u{9B}x", "+!touch PWNED", "-c!touch PWNED", "-", "--",
                       #"a\'; touch PWNED; '.md"#, #"\(touch)"#, #"\\(x)"#, #"x\"#, #"\n\t\a\r"#, "$$HOME$$", "$$$$", "a$$$b", "$",
                       "\"q\"", "\"\u{301}x", "'", "`touch PWNED`", "~x", " lead", "trail ", "tab\u{A0}nbsp", "line\u{2028}sep",
                       "\u{3000}ideo", "\u{202E}gnp.exe", "😀.md", "café.md", "x;y|z&w", "*", "[ab]", "!!", "sub/-x[1].txt"]
        for name in hostile {
            let edit = try EditorCommand.command(editor: "vim", file: name)
            for shell in ["/bin/zsh", "/opt/homebrew/bin/fish", "/bin/my shell's \"dir\"/bash"] {
                let argv = edit.argv(shell: shell)
                XCTAssertEqual(argvITerm2Runs(iTermShellforgeSidebar.commandLine(argv)), argv, name)
            }
            XCTAssertEqual(edit.argv(shell: "/bin/zsh"), ["/bin/zsh", "-l", "-i", "-c", #"exec vim -- "$1""#, "shellforge-open", "./" + name])
            let diff = try GitActions.diffCommand(for: GitChange(path: name, originalPath: "old " + name, letter: .renamed), staged: true)
            XCTAssertEqual(argvITerm2Runs(iTermShellforgeSidebar.commandLine(diff.argv(shell: "/bin/bash"))), diff.argv(shell: "/bin/bash"), name)
        }
    }

    /// A file's tab runs its own command in the folder, with no login shell to type into and none
    /// of the default profile's initial text; its title shows as it is.
    func testAFileTabRunsItsOwnCommand() {
        let base: [AnyHashable: Any] = [KEY_CUSTOM_COMMAND: "No", KEY_INITIAL_TEXT: "echo hi", KEY_RUN_COMMAND_IN_LOGIN_SHELL: true]
        let profile = iTermShellforgeSidebar.fileTabProfile(base: base, directory: "/tmp/demo", argv: ["/bin/zsh", "-c", "x"], title: "$$a$$.md")
        XCTAssertEqual(profile[KEY_CUSTOM_COMMAND] as? String, kProfilePreferenceCommandTypeCustomValue)
        XCTAssertEqual(profile[KEY_COMMAND_LINE] as? String, #""/bin/zsh" "-c" "x""#)
        XCTAssertEqual(profile[KEY_RUN_COMMAND_IN_LOGIN_SHELL] as? Bool, false)
        XCTAssertEqual(profile[KEY_INITIAL_TEXT] as? String, "")
        XCTAssertEqual(profile[KEY_WORKING_DIRECTORY] as? String, "/tmp/demo")
        let name = profile[KEY_NAME] as? String ?? ""
        XCTAssertEqual((name as NSString).performingSubstitutions(["$$$$": "$$"]), "$$a$$.md")
        XCTAssertTrue(((name as NSString).doubleDollarVariables() as? Set<String> ?? []).isSubset(of: ["$$$$"]))
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
        XCTAssertEqual(saved[ShellforgeTags.panel] as? String, "ssh:staging", "\(saved)")
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

    /// A panel the activity bar hides leaves the View menu: its item is hidden, which also takes
    /// its ⌃⌘ key out of matching, and refuses validation; shown again, the item is back.
    @MainActor func testAHiddenPanelLeavesTheViewMenu() throws {
        let saved = ShellforgeDefaultsSnapshot()
        let wasHidden = iTermShellforgeSidebar.activityOrder.hidden.contains(.ssh)
        defer {
            iTermShellforgeSidebar.activityOrder.setHidden(.ssh, wasHidden)
            saved.restore()
        }
        let tag = try XCTUnwrap(ActivityPanel.allCases.firstIndex(of: .ssh))
        let item = try XCTUnwrap(iTermShellforgeSidebar.panelMenuItems().first { $0.tag == tag })
        XCTAssertTrue(iTermShellforgeSidebar.activityOrder.setHidden(.ssh, true))
        XCTAssertTrue(item.isHidden)
        XCTAssertEqual((item.target as? NSMenuItemValidation)?.validateMenuItem(item), false)
        iTermShellforgeSidebar.activityOrder.setHidden(.ssh, false)
        XCTAssertFalse(item.isHidden)
    }
}
