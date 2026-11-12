// Ported from AiTerm (app/Tests/AiTermTests/AlertPromptTests.swift), GPLv3, Laurens D'Hondt.
import Testing
@testable import ShellforgeUI

/// ⎋ answers a question's safe choice. How an alert shows it — ↩ on the default, red only when it
/// deletes — is the app's `WarningPrompter`, tested in ModernTests/ShellforgeWarningPrompterTest.
@Suite struct AlertPromptTests {
    @Test func escapeFallsToCancelOrALoneButton() {
        #expect(AlertPrompt(message: "m", buttons: ["Remove", "Cancel"]).escapeButton == 1)
        #expect(AlertPrompt(message: "m").escapeButton == 0, "an OK-only alert: ⎋ is OK")
        #expect(AlertPrompt(message: "m", buttons: ["Import", "Skip"], escape: 1).escapeButton == 1)
        #expect(AlertPrompt(message: "m", buttons: ["Keep Task", "Delete Changes and Remove"], escape: 0).escapeButton == 0)
    }
}
