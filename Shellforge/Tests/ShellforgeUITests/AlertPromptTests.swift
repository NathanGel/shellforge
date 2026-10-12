// Ported from AiTerm (app/Tests/AiTermTests/AlertPromptTests.swift), GPLv3, Laurens D'Hondt.
import AppKit
import Testing
@testable import ShellforgeUI

/// Every alert has one default button, on ↩, blue — or red only when it deletes — and ⎋ answers
/// its safe choice. Built, never run: `ModalPrompter.alert(for:)` is the alert `ask` would show.
@Suite @MainActor struct AlertPromptTests {
    private static let escape = "\u{1b}", enter = "\r"

    @Test func onlyADefaultThatDeletesIsRed() {
        let remove = ModalPrompter.alert(for: AlertPrompt(message: "Remove task?", buttons: ["Remove", "Cancel"], defaultDeletes: true))
        #expect(remove.buttons.map(\.hasDestructiveAction) == [true, false])
        let project = ModalPrompter.alert(for: AlertPrompt(message: "Remove project?", buttons: ["Remove", "Cancel"]))
        #expect(project.buttons.map(\.hasDestructiveAction) == [false, false], "a project's files are kept: blue")
        let unsaved = ModalPrompter.alert(for: AlertPrompt(message: "Uncommitted changes",
                                                           buttons: ["Keep Task", "Delete Changes and Remove"], escape: 0))
        #expect(unsaved.buttons.map(\.hasDestructiveAction) == [false, false],
                "a destructive button that isn't the default is the plain grey one")
    }

    @Test func theDefaultAnswersReturnAndTheSafeChoiceEscape() {
        let remove = ModalPrompter.alert(for: AlertPrompt(message: "Remove task?", buttons: ["Remove", "Cancel"], defaultDeletes: true))
        #expect(remove.buttons.map(\.keyEquivalent) == [Self.enter, Self.escape])
        let later = ModalPrompter.alert(for: AlertPrompt(message: "Update?", buttons: ["Update", "Later"], escape: 1))
        #expect(later.buttons.map(\.keyEquivalent) == [Self.enter, Self.escape], "Later is handed ⎋: NSAlert gives it only to Cancel")
        // A safe default keeps ↩; `ask` answers ⎋ for it.
        let quit = ModalPrompter.alert(for: AlertPrompt(message: "Unsaved", buttons: ["Cancel Quit", "Quit Without Saving"], escape: 0))
        #expect(quit.buttons.map(\.keyEquivalent) == [Self.enter, ""])
    }

    @Test func escapeFallsToCancelOrALoneButton() {
        #expect(AlertPrompt(message: "m", buttons: ["Remove", "Cancel"]).escapeButton == 1)
        #expect(AlertPrompt(message: "m").escapeButton == 0, "an OK-only alert: ⎋ is OK")
        #expect(AlertPrompt(message: "m", buttons: ["Import", "Skip"], escape: 1).escapeButton == 1)
        #expect(AlertPrompt(message: "m", buttons: ["Keep Task", "Delete Changes and Remove"], escape: 0).escapeButton == 0)
    }
}
