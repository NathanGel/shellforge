import AppKit
import ShellforgeDesign
import SwiftUI

/// The Git panel's commit message: several lines, the first the subject. It grows with what is
/// typed, up to `maxLines`, then scrolls. ↩ adds a line; ⌘↩ is the field's own key, handled while
/// it has the keyboard, so it never reaches the main menu (where a profile may have put Toggle Full
/// Screen) or another section's Commit. `commit` decides whether a commit is made.
struct CommitMessageField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    @Binding var focused: Bool
    let font: NSFont
    let commit: () -> Void

    static let maxLines = 5
    static let accessibilityLabel = "Commit message"
    /// Space between the text and the field's box.
    static let inset = NSSize(width: Space.tight, height: Space.tight)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let textView = CommitTextView(frame: .zero)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        // A commit message is plain text: no curly quotes or dashes put in for the person.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = font
        textView.textColor = NSColor(Palette.text)
        textView.insertionPointColor = NSColor(Palette.text)
        textView.textContainerInset = Self.inset
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        textView.delegate = context.coordinator
        textView.setAccessibilityLabel(Self.accessibilityLabel)
        scroll.documentView = textView
        configure(textView, context: context)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? CommitTextView else { return }
        if textView.string != text { textView.string = text }
        if textView.font != font { textView.font = font }
        configure(textView, context: context)
    }

    private func configure(_ textView: CommitTextView, context: Context) {
        textView.setAccessibilityPlaceholderValue(placeholder)
        textView.onCommit = { [weak coordinator = context.coordinator] in coordinator?.parent.commit() }
        textView.onFocusChange = { [weak coordinator = context.coordinator] focused in
            guard let coordinator, coordinator.parent.focused != focused else { return }
            coordinator.parent.focused = focused
        }
    }

    /// As tall as its lines, one to `maxLines`, at the width offered.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? 240
        let lines = Self.lines(text, font: font, width: width)
        return CGSize(width: width, height: CGFloat(lines) * Self.lineHeight(font) + 2 * Self.inset.height)
    }

    static func lineHeight(_ font: NSFont) -> CGFloat { NSLayoutManager().defaultLineHeight(for: font) }

    /// The lines `text` takes at `width`, from one to `maxLines`.
    static func lines(_ text: String, font: NSFont, width: CGFloat) -> Int {
        // The text container's own padding, each side.
        let padding: CGFloat = 5
        let available = max(width - 2 * inset.width - 2 * padding, 1)
        // A last empty line, after a ↩, counts.
        let measured = text.isEmpty || text.hasSuffix("\n") ? text + "X" : text
        let height = (measured as NSString).boundingRect(with: NSSize(width: available, height: .greatestFiniteMagnitude),
                                                         options: [.usesLineFragmentOrigin], attributes: [.font: font]).height
        let lines = Int((height / lineHeight(font)).rounded(.up))
        return min(max(lines, 1), maxLines)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CommitMessageField
        init(_ parent: CommitMessageField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView, parent.text != textView.string else { return }
            parent.text = textView.string
        }
    }
}

/// The commit field's text view: ⌘↩ is its own, whether it comes as a key equivalent or a key.
final class CommitTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    /// ⌘↩ or ⌘⌤ (the keypad's Enter), with no other modifier.
    static func isCommitKey(_ event: NSEvent) -> Bool {
        let returnKeys: Set<UInt16> = [36, 76]
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        return event.type == .keyDown && returnKeys.contains(event.keyCode) && modifiers == .command
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if Self.isCommitKey(event), window?.firstResponder === self {
            onCommit?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if Self.isCommitKey(event) {
            onCommit?()
            return
        }
        super.keyDown(with: event)
    }

    /// Tab moves on, as in a field, rather than typing a tab into the message.
    override func insertTab(_ sender: Any?) { window?.selectNextKeyView(self) }
    override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(self) }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }
}
