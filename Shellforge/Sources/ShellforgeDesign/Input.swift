// Ported from AiTerm (app/Sources/AiTermUI/Input.swift), GPLv3, Laurens D'Hondt.
import AppKit
import SwiftUI

/// A plain text field dressed in the house field chrome; `secure` hides what is typed, for a token.
/// `caretAtEnd` puts the insertion point after the text when the field is focused, where AppKit
/// would select it all: for a value filled in as if typed — the Backpack sheet's saved password.
///
/// The field is AppKit's own `NSTextField` (`NSSecureTextField` for `secure`), as tall as AppKit
/// measures it for its font. SwiftUI's `TextField` takes its height from a line height SwiftUI
/// caches under the font object's address, and once a font is freed and another lands at that
/// address, the new one reads the old one's height: a body field laid out after the monospaced
/// branch field came out a point short in a few launches in a hundred.
public struct Input: View {
    let placeholder: String
    @Binding var text: String
    var monospaced: Bool
    var secure: Bool
    var caretAtEnd: Bool
    @Environment(\.interfaceScale) private var scale
    // `@State` is a macro in the macOS 26 SDK and its SwiftUIMacros plugin ships only with Xcode;
    // this is the storage and accessor the macro would generate. Private, and so kept out of the
    // initialiser: whether the field has the keyboard is the field's own business.
    private var _focused = State(initialValue: false)
    private var focused: Bool { get { _focused.wrappedValue } nonmutating set { _focused.wrappedValue = newValue } }

    public init(placeholder: String, text: Binding<String>, monospaced: Bool = false, secure: Bool = false,
                caretAtEnd: Bool = false) {
        self.placeholder = placeholder
        self._text = text
        self.monospaced = monospaced
        self.secure = secure
        self.caretAtEnd = caretAtEnd
    }

    public var body: some View {
        InputField(placeholder: placeholder, text: Self.edits(to: $text), focused: _focused.projectedValue,
                   font: (monospaced ? Typography.monoCode : Typography.body).scaled(by: scale).nsFont,
                   secure: secure, caretAtEnd: caretAtEnd)
            .fieldChrome(focused: focused)
    }

    /// The insertion point after the last character, nothing selected. In UTF-16, as `NSText` counts.
    static func placeCaretAtEnd(of editor: NSText) {
        editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
    }

    /// `binding`, passing on only real edits. A setter can have a side effect on the other end —
    /// open the ticket list, mark the branch hand-edited — that a value handed back unchanged, as
    /// a field does when editing begins or ends, must not fire.
    static func edits(to binding: Binding<String>) -> Binding<String> {
        Binding(get: { binding.wrappedValue }, set: { if $0 != binding.wrappedValue { binding.wrappedValue = $0 } })
    }
}

/// The AppKit field under an `Input`, configured as SwiftUI's plain `TextField` configured its
/// own: no bezel, no background and no AppKit focus ring (the chrome draws the house ring), one
/// line that scrolls rather than wraps.
private struct InputField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    @Binding var focused: Bool
    let font: NSFont
    /// Read once, when the field is made: no `Input` changes between a token and plain text.
    let secure: Bool
    /// The caret after the text on focus, rather than all of it selected (`Input.caretAtEnd`).
    let caretAtEnd: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let report: () -> Void = { [weak coordinator = context.coordinator] in coordinator?.focusBegan() }
        let field: NSTextField
        if secure {
            let secureField = FocusableSecureTextField()
            secureField.onFocus = report
            field = secureField
        } else {
            let plainField = FocusableTextField()
            plainField.onFocus = report
            field = plainField
        }
        field.delegate = context.coordinator
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.textColor = NSColor(Palette.text)
        field.font = font
        field.placeholderString = placeholder
        field.stringValue = text
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
        if field.font != font { field.font = font }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InputField
        weak var field: NSTextField?
        // Removed in a plain deinit: `isolated deinit` needs a newer runtime than macOS 13's.
        nonisolated(unsafe) private var undoObservers: [NSObjectProtocol] = []

        init(_ parent: InputField) {
            self.parent = parent
            super.init()
            // An undo or a redo changes the field editor's text without the change notification a
            // keystroke sends, so the caller would go on holding the text the person just undid.
            // The window's undo manager is shared, hence the check that the change was this field's.
            undoObservers = [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange].map {
                NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.editorChanged() }
                }
            }
        }

        deinit { undoObservers.forEach(NotificationCenter.default.removeObserver) }

        private func editorChanged() {
            guard let editor = field?.currentEditor() else { return }
            parent.text = editor.string
        }

        /// Focus arrives with the keyboard, not with the first edit: `controlTextDidBeginEditing`
        /// waits for a keystroke, which would leave a clicked field without its ring.
        func focusBegan() {
            if !parent.focused { parent.focused = true }
            guard parent.caretAtEnd else { return }
            // A turn later: AppKit selects the field's text as it hands it the keyboard.
            Task { [weak self] in
                if let editor = self?.field?.currentEditor() { Input.placeCaretAtEnd(of: editor) }
            }
        }
        func controlTextDidEndEditing(_ notification: Notification) { if parent.focused { parent.focused = false } }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
    }
}

/// `FocusableTextField`'s report of having the keyboard, for a field that hides what is typed.
final class FocusableSecureTextField: NSSecureTextField {
    /// Called when the field takes the keyboard, and when it keeps it through the end of an edit.
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?() }
        return became
    }

    /// See `FocusableTextField.textDidEndEditing(_:)`.
    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        if currentEditor() != nil { onFocus?() }
    }
}
