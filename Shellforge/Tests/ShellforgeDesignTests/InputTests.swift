// Ported from AiTerm (app/Tests/AiTermUITests/InputTests.swift), GPLv3, Laurens D'Hondt.
import AppKit
import ObjectiveC
import SwiftUI
import Testing
@testable import ShellforgeDesign

@MainActor
struct InputTests {
    /// AppKit hands a field's value back when editing begins and ends, not only when it changes.
    /// Only a real edit may reach the caller's binding: its setter can have a side effect — open
    /// the ticket list, mark the branch hand-edited — that clicking another field must not fire.
    @Test func onlyARealEditReachesTheBinding() {
        var value = "feat/login"
        var writes = 0
        let binding = Input.edits(to: Binding(get: { value }, set: { value = $0; writes += 1 }))

        binding.wrappedValue = "feat/logout"
        #expect(writes == 1)
        #expect(value == "feat/logout")

        binding.wrappedValue = "feat/logout"
        #expect(writes == 1)
    }

    /// A field is as tall as AppKit measures it for its font — a guard against going back to
    /// SwiftUI's own `TextField`. That one takes its single-line height from a line height SwiftUI
    /// caches under the font object's address, and a font freed and replaced at that address reads
    /// the old font's height: a body field drawn after the monospaced branch field came out a
    /// point short in a few launches in a hundred. Here `NSLayoutManager`, which that cache is
    /// filled from, answers wrong while the field is laid out — a stale entry on demand — which
    /// SwiftUI's field takes for its height and AppKit's never asks for.
    @Test(arguments: [false, true]) func aFieldIsAsTallAsAppKitMeasuresIt(monospaced: Bool) throws {
        let host = NSHostingView(rootView: Input(placeholder: "Name", text: .constant("shell 2"), monospaced: monospaced)
            .frame(width: 240))
        try withLineHeightsAnswering(40) {
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
        }
        let field = try #require(host.firstSubview(of: NSTextField.self))
        #expect(field.frame.height == field.intrinsicContentSize.height)
        #expect(field.frame.height < 20)
    }

    /// What is typed reaches the caller, and what the caller sets reaches the field — a token
    /// field included, which is AppKit's secure field.
    @Test(arguments: [false, true]) func typingAndTheCallersTextMeetInTheField(secure: Bool) throws {
        let state = TextState()
        let (window, host) = Self.host(StatefulInput(state: state, secure: secure))
        defer { window.orderOut(nil) }
        let field = try #require(host.firstSubview(of: NSTextField.self))
        #expect((field is NSSecureTextField) == secure)

        window.makeFirstResponder(field)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText("abc", replacementRange: NSRange(location: NSNotFound, length: 0))
        settle(host)
        #expect(state.text == "abc")

        state.text = "renamed"
        settle(host)
        #expect(field.stringValue == "renamed")
    }

    /// The house ring shows while the field has the keyboard — from the click, not the first
    /// keystroke — and goes when it leaves.
    @Test func theRingShowsWhileTheFieldHasTheKeyboard() throws {
        let (window, host) = Self.host(StatefulInput(state: TextState(), secure: false).padding(8).background(Color.black))
        defer { window.orderOut(nil) }
        let field = try #require(host.firstSubview(of: NSTextField.self))
        // Half a point outside the field box's left edge, where only the ring draws.
        let ring = NSPoint(x: 7.5, y: host.bounds.midY)
        #expect(try brightness(of: host, at: ring) == 0)

        window.makeFirstResponder(field)
        settle(host)
        #expect(try brightness(of: host, at: ring) > 0, "the field took the keyboard without its ring")

        window.makeFirstResponder(nil)
        settle(host)
        #expect(try brightness(of: host, at: ring) == 0, "the field lost the keyboard and kept its ring")
    }

    /// A plain ↩ in a field does nothing (docs/keyboard.md): AppKit ends the field's editing and
    /// selects its text again, the field keeps the keyboard, and so it keeps its ring.
    @Test(arguments: [false, true]) func returnLeavesTheFieldWithTheKeyboardAndItsRing(secure: Bool) throws {
        let (window, host) = Self.host(StatefulInput(state: TextState(), secure: secure).padding(8).background(Color.black))
        defer { window.orderOut(nil) }
        let field = try #require(host.firstSubview(of: NSTextField.self))
        let ring = NSPoint(x: 7.5, y: host.bounds.midY)
        window.makeFirstResponder(field)
        settle(host)

        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        settle(host)
        #expect(field.currentEditor() != nil, "↩ took the keyboard from the field")
        #expect(try brightness(of: host, at: ring) > 0, "↩ put the ring out while the field kept the keyboard")
    }

    /// ⌘Z is an edit too: what the field shows after an undo is what the caller holds.
    @Test(arguments: [false, true]) func anUndoneEditReachesTheBinding(secure: Bool) throws {
        let state = TextState()
        let (window, host) = Self.host(StatefulInput(state: state, secure: secure))
        defer { window.orderOut(nil) }
        let field = try #require(host.firstSubview(of: NSTextField.self))
        window.makeFirstResponder(field)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText("abc", replacementRange: NSRange(location: NSNotFound, length: 0))
        settle(host)
        #expect(state.text == "abc")

        let undo = try #require(editor.undoManager)
        #expect(undo.canUndo)
        undo.undo()
        settle(host)
        #expect(field.currentEditor()?.string == "")
        #expect(state.text == "", "the field shows the undone text and the caller still holds the edit")
    }

    private final class TextState: ObservableObject {
        @Published var text = ""
    }

    private struct StatefulInput: View {
        @ObservedObject var state: TextState
        let secure: Bool
        var body: some View {
            Input(placeholder: "Name", text: Binding(get: { state.text }, set: { state.text = $0 }), secure: secure)
                .frame(width: 240)
        }
    }

    private static func host(_ view: some View) -> (NSWindow, NSView) {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = window(hosting: host)
        settle(host)
        return (window, host)
    }

    /// The summed RGB of what `view` draws at `point`, in its own coordinates.
    private func brightness(of view: NSView, at point: NSPoint) throws -> CGFloat {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
        let y = view.isFlipped ? point.y : view.bounds.height - point.y
        let pixel = try #require(bitmap.colorAt(x: Int(point.x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB))
        return pixel.redComponent + pixel.greenComponent + pixel.blueComponent
    }

    /// Runs `body` with every `NSLayoutManager.defaultLineHeight(for:)` answering `height`.
    private func withLineHeightsAnswering(_ height: CGFloat, _ body: () throws -> Void) throws {
        let method = try #require(class_getInstanceMethod(NSLayoutManager.self,
                                                          #selector(NSLayoutManager.defaultLineHeight(for:))))
        let wrong: @convention(block) (AnyObject, NSFont) -> CGFloat = { _, _ in height }
        let original = method_setImplementation(method, imp_implementationWithBlock(wrong))
        defer { method_setImplementation(method, original) }
        try body()
    }
}
