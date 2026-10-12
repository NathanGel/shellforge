// Ported from AiTerm (app/Tests/AiTermTests/PromptEditorTests.swift and PromptCompletionTests.swift), GPLv3, Laurens D'Hondt.
import AppKit
import SwiftUI
import Combine
import ShellforgeCore
import ShellforgeDesign
import Testing
@testable import ShellforgeUI

@MainActor
@Suite struct PromptEditorTests {
    @Test func longPromptScrollsToTheInsertionPoint() throws {
        let text = TextBox()
        let completions = PromptCompletions()
        let editor = PromptEditor(text: Binding(get: { text.value }, set: { text.value = $0 }),
                                  agentId: "claude", completions: completions)
            .frame(width: 420, height: 150)
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 150)
        host.layoutSubtreeIfNeeded()

        let scrollView = try #require(descendant(of: NSScrollView.self, in: host))
        let textView = try #require(scrollView.documentView as? NSTextView)
        let longPrompt = (1...100).map { "Prompt line \($0)" }.joined(separator: "\n")
        textView.insertText(longPrompt, replacementRange: textView.selectedRange())
        textView.layoutManager?.ensureLayout(for: try #require(textView.textContainer))
        host.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()

        let layoutManager = try #require(textView.layoutManager)
        let textContainer = try #require(textView.textContainer)
        let lastCharacter = NSRange(location: (longPrompt as NSString).length - 1, length: 1)
        let lastGlyph = layoutManager.glyphRange(forCharacterRange: lastCharacter, actualCharacterRange: nil)
        var lastGlyphRect = layoutManager.boundingRect(forGlyphRange: lastGlyph, in: textContainer)
        lastGlyphRect.origin.x += textView.textContainerInset.width
        lastGlyphRect.origin.y += textView.textContainerInset.height

        #expect(textView.frame.height > scrollView.contentSize.height)
        #expect(textView.selectedRange().location == (longPrompt as NSString).length)
        #expect(textView.visibleRect.contains(CGPoint(x: lastGlyphRect.midX, y: lastGlyphRect.midY)))
    }

    /// Every caret move outside a `/` token closes the popup. Closing one already closed — the
    /// popup's list empty and its first row highlighted — changes nothing the popup draws, so the
    /// popup is not redrawn for each keystroke.
    @Test func closingAClosedPopupRedrawsNothing() {
        let completions = PromptCompletions()
        #expect(!announces(completions, { completions.close() }))

        completions.visible = [AgentCompletion(name: "review", kind: .command, detail: nil, source: .builtIn)]
        completions.index = 0
        #expect(announces(completions, { completions.close() }), "closing an open one does")
        completions.visible = [AgentCompletion(name: "review", kind: .command, detail: nil, source: .builtIn),
                               AgentCompletion(name: "loop", kind: .skill, detail: nil, source: .user)]
        completions.index = 1
        completions.close()
        #expect(completions.visible.isEmpty && completions.index == 0)
    }

    /// The prompt field wears the house focus ring like every other field, so the editor has to say
    /// when its text view takes the keyboard and when it gives it up.
    @Test func theEditorReportsFocus() throws {
        let text = TextBox()
        var focus: [Bool] = []
        let editor = PromptEditor(text: Binding(get: { text.value }, set: { text.value = $0 }),
                                  agentId: "claude", completions: PromptCompletions(),
                                  onFocusChange: { focus.append($0) })
            .frame(width: 420, height: 150)
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 150)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()

        let textView = try #require(descendant(of: NSScrollView.self, in: host)?.documentView as? NSTextView)
        window.makeFirstResponder(textView)
        #expect(focus == [true])
        window.makeFirstResponder(nil)
        #expect(focus == [true, false])
    }

    /// `PromptStep` lays its placeholder on these two numbers, so the text view must really use
    /// them — not AppKit's defaults, which only happen to agree today.
    @Test func theTextSitsOnTheInsetThePlaceholderReads() throws {
        let text = TextBox()
        let editor = PromptEditor(text: Binding(get: { text.value }, set: { text.value = $0 }),
                                  agentId: "claude", completions: PromptCompletions())
            .frame(width: 420, height: 150)
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 150)
        host.layoutSubtreeIfNeeded()
        let textView = try #require(descendant(of: NSScrollView.self, in: host)?.documentView as? NSTextView)
        #expect(textView.textContainerInset == PromptEditor.textInset)
        #expect(textView.textContainer?.lineFragmentPadding == PromptEditor.lineFragmentPadding)
    }

    @Test func popupOpenedNearTheRightEdgeStaysInsideTheField() throws {
        let text = TextBox()
        let completions = PromptCompletions()
        completions.all = [AgentCompletion(name: "brainstorming", kind: .skill, detail: nil, source: .user)]
        let editor = PromptEditor(text: Binding(get: { text.value }, set: { text.value = $0 }),
                                  agentId: "claude", completions: completions)
            .frame(width: 420, height: 150)
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 150)
        host.layoutSubtreeIfNeeded()

        let scrollView = try #require(descendant(of: NSScrollView.self, in: host))
        let textView = try #require(scrollView.documentView as? NSTextView)
        textView.insertText("Please look at this and then run /bra", replacementRange: textView.selectedRange())

        let popupWidth: CGFloat = 380
        #expect(completions.isOpen)
        #expect(completions.anchor.x + popupWidth > 420, "the token must start far enough right to overflow")
        #expect(completions.fieldWidth == 420)
        let leading = CompletionPopup.leading(anchorX: completions.anchor.x, width: popupWidth,
                                              fieldWidth: completions.fieldWidth)
        #expect(leading >= 0)
        #expect(leading + popupWidth <= completions.fieldWidth)
    }

    /// ↩ is the one key that accepts a suggestion; ⇥ is left to the text view.
    @Test func onlyReturnAcceptsASuggestion() throws {
        let text = TextBox()
        let completions = PromptCompletions()
        completions.all = [AgentCompletion(name: "brainstorming", kind: .skill, detail: nil, source: .user)]
        let editor = PromptEditor(text: Binding(get: { text.value }, set: { text.value = $0 }),
                                  agentId: "claude", completions: completions)
            .frame(width: 420, height: 150)
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 150)
        host.layoutSubtreeIfNeeded()

        let scrollView = try #require(descendant(of: NSScrollView.self, in: host))
        let textView = try #require(scrollView.documentView as? NSTextView)
        let delegate = try #require(textView.delegate)
        textView.insertText("/bra", replacementRange: textView.selectedRange())
        #expect(completions.isOpen)

        #expect(delegate.textView?(textView, doCommandBy: #selector(NSResponder.insertTab(_:))) == false)
        #expect(text.value == "/bra", "⇥ must not accept")
        #expect(delegate.textView?(textView, doCommandBy: #selector(NSResponder.insertNewline(_:))) == true)
        #expect(text.value.hasPrefix("/brainstorming"))
    }

    /// The popup answers its keys through `DropdownKeys`, as every dropdown does: arrows wrap,
    /// ↩ accepts the highlighted row, ⎋ closes only the popup, and a closed popup hands every key
    /// back to the text view.
    @Test func thePopupAnswersItsKeysAsEveryDropdownDoes() throws {
        let text = TextBox()
        let completions = PromptCompletions()
        completions.all = ["alpha", "alpine", "alps"].map { AgentCompletion(name: $0, kind: .skill, detail: nil, source: .user) }
        let editor = PromptEditor(text: Binding(get: { text.value }, set: { text.value = $0 }),
                                  agentId: "claude", completions: completions)
            .frame(width: 420, height: 150)
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 150)
        host.layoutSubtreeIfNeeded()
        let textView = try #require(descendant(of: NSScrollView.self, in: host)?.documentView as? NSTextView)
        let delegate = try #require(textView.delegate)
        func send(_ selector: Selector) -> Bool { delegate.textView?(textView, doCommandBy: selector) ?? false }

        #expect(!send(#selector(NSResponder.moveDown(_:))), "closed: the text view keeps its arrows")
        textView.insertText("/al", replacementRange: textView.selectedRange())
        #expect(completions.visible.count == 3 && completions.index == 0)

        #expect(send(#selector(NSResponder.moveUp(_:))) && completions.index == 2, "up from the first wraps to the last")
        #expect(send(#selector(NSResponder.moveDown(_:))) && completions.index == 0, "down from the last wraps to the first")
        #expect(send(#selector(NSResponder.moveDown(_:))) && completions.index == 1)
        completions.index = 9
        #expect(send(#selector(NSResponder.insertNewline(_:))), "a stale index accepts the last row, not out of bounds")
        #expect(text.value == "/alps ")

        textView.insertText("/al", replacementRange: textView.selectedRange())
        #expect(completions.isOpen)
        #expect(send(#selector(NSResponder.cancelOperation(_:))) && !completions.isOpen, "⎋ closes the popup")
        #expect(!send(#selector(NSResponder.cancelOperation(_:))), "and the next one is the sheet's")
    }

    /// Codex opens the popup from `/` like every agent, and a skill picked there is written as the
    /// `$` mention Codex runs it by.
    @Test func aCodexSkillPickedFromSlashIsWrittenAsItsMention() throws {
        let text = TextBox()
        let completions = PromptCompletions()
        completions.all = [AgentCompletion(name: "imagegen", kind: .skill, detail: nil, source: .builtIn)]
        let editor = PromptEditor(text: Binding(get: { text.value }, set: { text.value = $0 }),
                                  agentId: "codex", completions: completions)
            .frame(width: 420, height: 150)
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 150)
        host.layoutSubtreeIfNeeded()

        let textView = try #require(descendant(of: NSScrollView.self, in: host)?.documentView as? NSTextView)
        let delegate = try #require(textView.delegate)
        textView.insertText("draw /imag", replacementRange: textView.selectedRange())
        #expect(completions.isOpen)
        #expect(delegate.textView?(textView, doCommandBy: #selector(NSResponder.insertNewline(_:))) == true)
        #expect(text.value == "draw $imagegen ")
    }

    @Test func popupKeepsItsCaretPositionWhenItFits() {
        #expect(CompletionPopup.leading(anchorX: 12, width: 200, fieldWidth: 420) == 12)
        #expect(CompletionPopup.leading(anchorX: 300, width: 200, fieldWidth: 420) == 220)
        #expect(CompletionPopup.leading(anchorX: 300, width: 500, fieldWidth: 420) == 0)
    }

    @Test func droppedFilesAreInsertedAsTheirPaths() throws {
        let text = TextBox()
        let editor = PromptEditor(text: Binding(get: { text.value }, set: { text.value = $0 }),
                                  agentId: "claude", completions: PromptCompletions())
            .frame(width: 420, height: 150)
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 150)
        host.layoutSubtreeIfNeeded()

        let scrollView = try #require(descendant(of: NSScrollView.self, in: host))
        let textView = try #require(scrollView.documentView as? NSTextView)
        #expect(textView.acceptableDragTypes.contains(.fileURL))
        textView.insertText("Look at", replacementRange: textView.selectedRange())

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("aiterm-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/Screenshot 1.png") as NSURL,
                                 URL(fileURLWithPath: "/tmp/spec.pdf") as NSURL])
        #expect(textView.readSelection(from: pasteboard, type: .fileURL))

        #expect(text.value == #"Look at /tmp/Screenshot\ 1.png /tmp/spec.pdf "#)
    }

    @Test func droppedPathsAreEscapedLikeATerminalDrop() {
        #expect(PromptTextView.insertion(for: ["/a/b.png"], after: nil) == "/a/b.png ")
        #expect(PromptTextView.insertion(for: ["/a/b.png"], after: " ") == "/a/b.png ")
        #expect(PromptTextView.insertion(for: ["/a/b.png"], after: "x") == " /a/b.png ")
        #expect(PromptTextView.insertion(for: ["/a/it's (1).pdf", "/c"], after: "\n") == #"/a/it\'s\ \(1\).pdf /c "#)
    }

    private final class TextBox { var value = "" }

    private func descendant<T: NSView>(of type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = descendant(of: type, in: subview) { return match }
        }
        return nil
    }

    /// Whether `change` tells the popup to redraw: `@Published` announces through `objectWillChange`
    /// where AiTerm's `@Observable` invalidated the views that read it.
    private func announces(_ completions: PromptCompletions, _ change: () -> Void) -> Bool {
        var fired = false
        let watch = completions.objectWillChange.sink { fired = true }
        change()
        watch.cancel()
        return fired
    }

    /// The hint names the one key, for every agent, Codex included.
    @Test func completionHintAdvertisesSlashOnly() {
        #expect(CompletionHint.text == "Type / for commands and skills.")
    }

    /// The trigger counts Characters, not UTF-16: "é /bra" has its token at 2..<6.
    @Test func acceptReplacesExactlyTheTypedToken() throws {
        let text = "é /bra"
        let trigger = try #require(SkillCatalog.trigger(in: text, caret: text.count))
        #expect(trigger.query == "bra" && trigger.range == 2..<6)
    }

    /// ⎋ with the popup open closes the popup and nothing else; the next ⎋ is the step's.
    @Test func escapeClosesThePopupBeforeTheStep() {
        let completions = PromptCompletions()
        completions.all = [AgentCompletion(name: "brainstorming", kind: .skill, detail: nil, source: .user)]
        completions.visible = completions.all
        #expect(NewTaskSheet.closeList(step: 3, completions: completions))
        #expect(!completions.isOpen)
        #expect(!NewTaskSheet.closeList(step: 3, completions: completions), "the next ⎋ goes back a step")
        completions.visible = completions.all
        #expect(!NewTaskSheet.closeList(step: 1, completions: completions), "no popup on the task step")
    }
}
