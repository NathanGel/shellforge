import Foundation

/// A first prompt typed into a running agent: one bracketed paste, then Return.
public enum TypedPrompt {
    private static let start = "\u{1B}[200~", end = "\u{1B}[201~"

    /// The bytes to write to the terminal. The prompt can't act as a keystroke or end the paste
    /// early, whatever it holds: a CRLF or lone CR is a newline, which a paste keeps instead of
    /// submitting, and every other control character is dropped, ESC first among them, so no end
    /// marker, escape sequence or ^C, ^D or ^U gets through. A TAB and newlines stay.
    public static func paste(_ prompt: String) -> String {
        let text = prompt.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var body = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let control = scalar.value < 0x20 || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value)
            if !control || scalar == "\n" || scalar == "\t" { body.append(scalar) }
        }
        return start + String(body) + end + "\r"
    }
}
