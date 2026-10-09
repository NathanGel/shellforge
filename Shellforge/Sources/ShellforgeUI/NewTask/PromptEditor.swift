// Ported from AiTerm (app/Sources/AiTerm/Views/PromptEditor.swift), GPLv3, Laurens D'Hondt.
import AppKit
import ShellforgeDesign
import SwiftUI

/// The first-prompt editor: a real `NSTextView`, as AiTerm's is. AiTerm's opens a popup of the
/// agent's commands and skills on `/`; that arrives with M1c-3d, and the view stays AppKit's so it
/// can. Files dropped or pasted from Finder — screenshots, PDFs, anything — go in as their paths.
struct PromptEditor: NSViewRepresentable {
    @Binding var text: String
    /// Told when the text view takes the keyboard and when it gives it up, so the field around it
    /// can draw the focus ring.
    var onFocusChange: (Bool) -> Void = { _ in }
    /// Takes the keyboard as soon as the editor is in a window, so arriving on the prompt step
    /// puts the caret in the field without a click.
    var focusOnAppear = false

    /// Where the text sits inside the field's box: `Space.snug` in from the side, `Space.base` down
    /// from the top. `PromptStep` lays its placeholder on the same inset.
    static let textInset = CGSize(width: Space.snug, height: Space.base)
    /// The gap `NSTextContainer` leaves before a line's first glyph, past `textInset`. AppKit's own
    /// default, set explicitly so the placeholder can add the same amount rather than assume it.
    static let lineFragmentPadding: CGFloat = 5

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1, explicitly, as AiTerm's: the completion popup (M1c-3d) anchors to a caret
        // rectangle that comes from `NSLayoutManager`.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: CGFloat(0), height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = Self.lineFragmentPadding
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)

        let textView = PromptTextView(frame: .zero, textContainer: container)
        textView.delegate = context.coordinator
        textView.onFocusChange = { [weak coordinator = context.coordinator] in coordinator?.parent.onFocusChange($0) }
        textView.wantsFocus = focusOnAppear
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = Typography.promptMono.nsFont
        textView.textColor = NSColor(Palette.text)
        textView.insertionPointColor = NSColor(Palette.accent)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = Self.textInset
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.string = text

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text {
            let selected = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(NSRange(location: min(selected.location, (text as NSString).length), length: 0))
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptEditor
        weak var textView: NSTextView?
        init(_ parent: PromptEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

/// A plain-text view that takes files as their paths, the way a drop into iTerm2 does, so the
/// agent gets something it can open. Rich text is off, so without this a dropped image would
/// either be refused or read in as its contents.
final class PromptTextView: NSTextView {
    /// What iTerm2 backslash-escapes in a dropped path, so the agent reads the same thing it would
    /// if the file were dropped into its own terminal.
    private static let special = Set(#"\'"()[]{}<>$&;|*?!#~`"#)

    /// Called with `true` when the view takes the keyboard and `false` when it gives it up.
    var onFocusChange: ((Bool) -> Void)?
    /// Whether to take the keyboard once, on joining a window. SwiftUI inserts the representable
    /// before it has one, so asking at `makeNSView` would find no window to ask.
    var wantsFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard wantsFocus, let window else { return }
        wantsFocus = false
        window.makeFirstResponder(self)
    }

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

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes.contains(.fileURL) ? super.acceptableDragTypes : super.acceptableDragTypes + [.fileURL]
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.fileURL] + super.readablePasteboardTypes.filter { $0 != .fileURL }
    }

    override func dragOperation(for dragInfo: NSDraggingInfo, type: NSPasteboard.PasteboardType) -> NSDragOperation {
        type == .fileURL ? .copy : super.dragOperation(for: dragInfo, type: type)
    }

    /// Both a drop and ⌘V land here, with the selection already at the drop point.
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return super.readSelection(from: pboard, type: type) }
        let range = selectedRange()
        let before = range.location > 0 ? (string as NSString).substring(with: NSRange(location: range.location - 1, length: 1)).first : nil
        insertText(Self.insertion(for: urls.map(\.path), after: before), replacementRange: range)
        return true
    }

    /// The paths, space-separated and escaped, with a space before them unless the caret already
    /// follows whitespace and one after so typing can carry on.
    static func insertion(for paths: [String], after previous: Character?) -> String {
        let escaped = paths.map { path in
            path.reduce(into: "") { out, c in
                if c.isWhitespace || special.contains(c) { out.append("\\") }
                out.append(c)
            }
        }
        let lead = previous.map { $0.isWhitespace ? "" : " " } ?? ""
        return lead + escaped.joined(separator: " ") + " "
    }
}
