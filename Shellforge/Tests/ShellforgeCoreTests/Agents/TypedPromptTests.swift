import Testing
@testable import ShellforgeCore

@Suite struct TypedPromptTests {
    @Test func pasteWraps() {
        #expect(TypedPrompt.paste("fix it") == "\u{1B}[200~fix it\u{1B}[201~\r")
    }

    @Test func pasteCannotBeEndedEarly() {
        let pasted = TypedPrompt.paste("a\u{1B}[201~b\r\nc")
        // The ESC goes, so what is left of the marker is plain text.
        #expect(pasted == "\u{1B}[200~a[201~b\nc\u{1B}[201~\r")
        #expect(pasted.components(separatedBy: "\u{1B}[201~").count == 2)
        #expect(TypedPrompt.paste("\u{1B}[20\u{1B}[201~1~") == "\u{1B}[200~[20[201~1~\u{1B}[201~\r")
    }

    @Test func escapeAndControlBytesAreDropped() {
        #expect(TypedPrompt.paste("a\u{1B}") == "\u{1B}[200~a\u{1B}[201~\r")
        #expect(TypedPrompt.paste("a\u{1B}[200~b") == "\u{1B}[200~a[200~b\u{1B}[201~\r")
        #expect(TypedPrompt.paste("a\rb") == "\u{1B}[200~a\nb\u{1B}[201~\r")
        #expect(TypedPrompt.paste("a\u{03}b\u{04}c\u{15}d\u{7F}e\u{9B}f") == "\u{1B}[200~abcdef\u{1B}[201~\r")
        #expect(TypedPrompt.paste("a\tb\nc") == "\u{1B}[200~a\tb\nc\u{1B}[201~\r")
        let inner = TypedPrompt.paste("x\u{1B}[201~\u{1B}\u{03}y").dropFirst(6).dropLast(7)
        #expect(!inner.unicodeScalars.contains { $0.value < 0x20 && $0 != "\n" && $0 != "\t" })
    }
}
