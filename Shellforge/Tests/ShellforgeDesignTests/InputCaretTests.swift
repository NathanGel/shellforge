// Ported from AiTerm (app/Tests/AiTermUITests/InputCaretTests.swift), GPLv3, Laurens D'Hondt.
import AppKit
import Testing
@testable import ShellforgeDesign

@MainActor
struct InputCaretTests {
    /// `caretAtEnd`: focusing a filled field puts the insertion point after its last character, as
    /// if the text had just been typed, rather than selecting it all as AppKit does on focus.
    @Test func theCaretGoesAfterTheLastCharacter() {
        let editor = NSTextView()
        editor.string = "hunter2"
        editor.setSelectedRange(NSRange(location: 0, length: 7))
        Input.placeCaretAtEnd(of: editor)
        #expect(editor.selectedRange() == NSRange(location: 7, length: 0))
    }

    /// Counted in UTF-16, as NSText counts: a password with an emoji still ends past its last unit.
    @Test func theEndCountsUTF16() {
        let editor = NSTextView()
        editor.string = "pa🔑"
        Input.placeCaretAtEnd(of: editor)
        #expect(editor.selectedRange() == NSRange(location: ("pa🔑" as NSString).length, length: 0))
    }
}
