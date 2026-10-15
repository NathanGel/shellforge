// Ported from AiTerm (app/Sources/AiTermUI/SearchField.swift), GPLv3, Laurens D'Hondt.
import AppKit
import SwiftUI

/// A single-line field whose AppKit delegate can give an open popup first refusal on navigation
/// commands. SwiftUI's `TextField` does not expose that delegate hook.
public struct SearchField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    @Binding var focused: Bool
    let onCommand: (Selector) -> Bool

    public init(placeholder: String, text: Binding<String>, focused: Binding<Bool>,
                onCommand: @escaping (Selector) -> Bool) {
        self.placeholder = placeholder; self._text = text; self._focused = focused; self.onCommand = onCommand
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public func makeNSView(context: Context) -> FocusableTextField {
        let field = FocusableTextField()
        field.delegate = context.coordinator
        field.onFocus = { [weak coordinator = context.coordinator] in coordinator?.focusBegan() }
        field.wantsFocus = focused
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Typography.body.nsFont
        field.textColor = NSColor(Palette.text)
        field.placeholderString = placeholder
        field.stringValue = text
        return field
    }

    public func updateNSView(_ field: FocusableTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
        // A disabled form — a sheet while it creates — takes no typing here, nor keeps the focus.
        let enabled = context.environment.isEnabled
        if field.isEditable != enabled { field.isEditable = enabled }
        guard enabled else {
            field.wantsFocus = false
            if let editor = field.currentEditor(), field.window?.firstResponder === editor { field.window?.makeFirstResponder(nil) }
            return
        }
        field.wantsFocus = focused
        field.focusIfNeeded()
    }

    @MainActor
    public final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchField
        init(_ parent: SearchField) { self.parent = parent }

        /// Focus arrives with the keyboard, not with the first edit: `controlTextDidBeginEditing`
        /// waits for a keystroke, which left a clicked field without its ring. Written only on a
        /// change, since taking focus from `updateNSView` lands here too.
        func focusBegan() { if !parent.focused { parent.focused = true } }
        public func controlTextDidEndEditing(_ notification: Notification) { if parent.focused { parent.focused = false } }

        public func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            parent.onCommand(commandSelector)
        }
    }
}

/// Focus may be requested before SwiftUI inserts the representable into a window (notably when a
/// picked item is cleared). Retrying at window attachment makes that request deterministic.
public final class FocusableTextField: NSTextField {
    var wantsFocus = false
    /// Called when the field takes the keyboard, and when it keeps it through the end of an edit.
    var onFocus: (() -> Void)?

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusIfNeeded()
    }

    public override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?() }
        return became
    }

    /// A plain ↩ ends the edit — the delegate hears `controlTextDidEndEditing` and drops focus —
    /// and AppKit then selects the text again without a new `becomeFirstResponder`: the field
    /// still has the keyboard, so it says so again, or its ring would stay out while it is typed in.
    public override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        if currentEditor() != nil { onFocus?() }
    }

    func focusIfNeeded() {
        guard wantsFocus, currentEditor() == nil else { return }
        window?.makeFirstResponder(self)
    }
}
