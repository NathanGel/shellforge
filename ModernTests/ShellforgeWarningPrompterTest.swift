//
//  ShellforgeWarningPrompterTest.swift
//  ModernTests
//
//  The sidebar's questions go through iTermWarning, so they are published to the registry the
//  paired phone reads and can be answered there. Headless: nothing is put on screen. Each question
//  is answered through ModalAlertRegistry, as the phone would, from off the main thread.
//

import AppKit
import ShellforgeUI
import XCTest
@testable import iTerm2SharedARC

final class ShellforgeWarningPrompterTest: XCTestCase {
    override func setUp() {
        super.setUp()
        iTermWarning.setRunsHeadlessModals(true)
    }

    override func tearDown() {
        iTermWarning.cancelHeadlessModals()
        iTermWarning.setRunsHeadlessModals(false)
        super.tearDown()
    }

    /// Ends a question still waiting, which holds the main thread in its nested run loop, so a
    /// failing test does not hang. From a run loop block: the main queue may be frozen.
    private static func cancelHeadlessModals() {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
            iTermWarning.cancelHeadlessModals()
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    /// Asks `prompt` through a `WarningPrompter`, presses `button` (ticking the checkbox if
    /// `ticking`) through the registry once the question is shown, and returns what was shown and
    /// what `ask` answered.
    private func ask(_ prompt: AlertPrompt, pressing button: Int,
                     ticking: Bool = false) async throws -> (shown: ModalAlertSnapshot, answer: AlertAnswer) {
        let registry = ModalAlertRegistry.shared
        let (changes, changesContinuation) = AsyncStream<Void>.makeStream()
        let token = registry.addObserver { changesContinuation.yield() }
        defer { withExtendedLifetime(token) {} }
        let (answers, answersContinuation) = AsyncStream<AlertAnswer>.makeStream()
        Task { @MainActor in
            answersContinuation.yield(await WarningPrompter().ask(prompt))
        }
        do {
            let shown = try await FrozenMainQueue.withFailsafe("the question to be shown") { () -> ModalAlertSnapshot in
                for await _ in changes {
                    if let top = registry.currentAlerts().last {
                        return top
                    }
                }
                throw CancellationError()
            }
            let accepted = try await FrozenMainQueue.withFailsafe("the press") {
                await registry.answer(id: shown.id, buttonIndex: button, suppress: ticking)
            }
            XCTAssertTrue(accepted)
            if !accepted {
                Self.cancelHeadlessModals()
            }
            let answer = try await FrozenMainQueue.withFailsafe("ask to return") { () -> AlertAnswer in
                for await answer in answers {
                    return answer
                }
                throw CancellationError()
            }
            return (shown, answer)
        } catch {
            Self.cancelHeadlessModals()
            throw error
        }
    }

    func testAPromptShowsItsButtonsInOrder() async throws {
        let prompt = AlertPrompt(message: "Remove task?", detail: "The worktree of feature/login-page is deleted.",
                                 buttons: ["Remove", "Keep Branch", "Cancel"], defaultDeletes: true)
        let (shown, answer) = try await ask(prompt, pressing: 1)
        XCTAssertEqual(shown.heading, "Remove task?")
        XCTAssertEqual(shown.body, "The worktree of feature/login-page is deleted.")
        XCTAssertEqual(shown.buttons.map(\.title), ["Remove", "Keep Branch", "Cancel"])
        XCTAssertEqual(shown.buttons.map(\.isDestructive), [true, false, false], "only a default that deletes is red")
        XCTAssertEqual(shown.buttons.map(\.isCancel), [false, false, true], "Cancel is the safe choice")
        XCTAssertEqual(shown.buttons.map(\.offered), [true, true, true])
        XCTAssertNil(shown.suppressionLabel, "never silenceable")
        XCTAssertFalse(shown.hasAccessory)
        XCTAssertTrue(shown.isAppModal)
        XCTAssertEqual(answer, AlertAnswer(button: 1))
        XCTAssertEqual(ModalAlertRegistry.shared.currentAlerts(), [], "the question unregistered when answered")
    }

    func testTheFirstButtonAnswersConfirmed() async throws {
        let prompt = AlertPrompt(message: "Delete branch feature/login-page?", buttons: ["Delete Branch", "Cancel"],
                                 defaultDeletes: true)
        let (_, answer) = try await ask(prompt, pressing: 0)
        XCTAssertTrue(answer.confirmed)
        XCTAssertEqual(answer.button, 0)
    }

    func testACheckboxAnswerComesBack() async throws {
        let prompt = AlertPrompt(message: "Remove project demo?", buttons: ["Remove", "Cancel"],
                                 checkbox: "Also delete the worktrees")
        let (shown, ticked) = try await ask(prompt, pressing: 0, ticking: true)
        XCTAssertEqual(shown.suppressionLabel, "Also delete the worktrees", "the phone shows the checkbox")
        XCTAssertFalse(shown.suppressionDefault)
        XCTAssertEqual(ticked, AlertAnswer(button: 0, checked: true))

        let (_, unticked) = try await ask(prompt, pressing: 0, ticking: false)
        XCTAssertEqual(unticked, AlertAnswer(button: 0, checked: false))

        // The sub-checkbox has no place on the phone: it stays unticked, and the phone is told more
        // is shown on the Mac.
        let pair = AlertPrompt(message: "Remove task?", buttons: ["Remove", "Cancel"],
                               checkbox: "Also delete the worktree", subCheckbox: "Also delete branch")
        let (pairShown, pairAnswer) = try await ask(pair, pressing: 0, ticking: true)
        XCTAssertEqual(pairShown.suppressionLabel, "Also delete the worktree")
        XCTAssertTrue(pairShown.hasAccessory)
        XCTAssertEqual(pairAnswer, AlertAnswer(button: 0, checked: true, subChecked: false))
    }

    /// The sub-checkbox, at the Mac, is enabled only while the checkbox is ticked, and counts only
    /// with it.
    @MainActor
    func testTheSubCheckboxFollowsTheCheckbox() throws {
        let prompt = AlertPrompt(message: "Remove task?", buttons: ["Remove", "Cancel"],
                                 checkbox: "Also delete the worktree", subCheckbox: "Also delete branch")
        let question = WarningPrompter.question(for: prompt)
        let checkbox = try XCTUnwrap(question.checkbox)
        let sub = try XCTUnwrap(question.subCheckbox)
        XCTAssertFalse(sub.isEnabled)
        checkbox.performClick(nil)
        XCTAssertTrue(sub.isEnabled)
        sub.performClick(nil)
        XCTAssertEqual(question.answer(.kiTermWarningSelection0, to: prompt),
                       AlertAnswer(button: 0, checked: true, subChecked: true))
        checkbox.performClick(nil)
        XCTAssertFalse(sub.isEnabled)
        XCTAssertEqual(sub.state, .off, "unticking the checkbox unticks the one under it")
        XCTAssertEqual(question.answer(.kiTermWarningSelection0, to: prompt), AlertAnswer(button: 0))
    }

    /// ⎋ answers the safe button: Cancel by itself, another safe button through its key
    /// equivalent, and a safe default — which holds ↩ — through the key monitor `ask` installs.
    @MainActor
    func testEscapeAnswersTheSafeButton() throws {
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: 0, context: nil, characters: WarningPrompter.escapeKey,
                                                    charactersIgnoringModifiers: WarningPrompter.escapeKey,
                                                    isARepeat: false, keyCode: 53))
        // Laid out, as runModal would, only where the buttons must be in the window: laying out
        // takes ↩ off a destructive default (AppKit's doing, with or without iTermWarning).
        func built(_ prompt: AlertPrompt, laidOut: Bool = false) -> NSAlert {
            let alert = WarningPrompter.question(for: prompt).warning.makeAlertForRemoteAnswer()
            if laidOut {
                alert.layout()
            }
            return alert
        }

        let remove = AlertPrompt(message: "Remove task?", buttons: ["Remove", "Cancel"], defaultDeletes: true)
        XCTAssertEqual(built(remove).buttons.map(\.keyEquivalent), [WarningPrompter.returnKey, WarningPrompter.escapeKey])

        let later = AlertPrompt(message: "Update?", buttons: ["Update", "Later"], escape: 1)
        let laterAlert = built(later, laidOut: true)
        XCTAssertEqual(laterAlert.buttons.map(\.keyEquivalent), [WarningPrompter.returnKey, WarningPrompter.escapeKey],
                       "Later is handed ⎋: NSAlert gives it only to Cancel")
        XCTAssertNil(WarningPrompter.defaultButton(answeringEscape: escape, in: laterAlert.window, for: later),
                     "the monitor leaves ⎋ to the button that holds it")

        let keep = AlertPrompt(message: "Uncommitted changes in src/app.ts",
                               buttons: ["Keep Task", "Delete Changes and Remove"], escape: 0)
        let keepAlert = built(keep, laidOut: true)
        XCTAssertEqual(keepAlert.buttons.first?.keyEquivalent, WarningPrompter.returnKey, "a safe default keeps ↩")
        XCTAssertNotEqual(keepAlert.buttons.last?.keyEquivalent, WarningPrompter.escapeKey)
        let pressed = WarningPrompter.defaultButton(answeringEscape: escape, in: keepAlert.window, for: keep)
        XCTAssertTrue(pressed === keepAlert.buttons.first, "⎋ presses the safe default")

        let shifted = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0,
                                                     windowNumber: 0, context: nil, characters: WarningPrompter.escapeKey,
                                                     charactersIgnoringModifiers: WarningPrompter.escapeKey,
                                                     isARepeat: false, keyCode: 53))
        XCTAssertNil(WarningPrompter.defaultButton(answeringEscape: shifted, in: keepAlert.window, for: keep))
    }
}
