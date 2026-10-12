// Ported from AiTerm (app/Tests/AiTermTests/CompletionPopupLayeringTests.swift), GPLv3, Laurens D'Hondt.
import AppKit
import SwiftUI
import ShellforgeCore
import ShellforgeDesign
import Testing
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// The completion popup hangs out of the prompt field, over the hint, the checkbox and the command
/// preview below it. It has to draw over all of them, on a fill of its own: it used to sit under
/// the command preview — a later sibling in the sheet's stack — on the sheet's own colour, so the
/// preview's text showed straight through it.
@MainActor
@Suite(.serialized) struct CompletionPopupLayeringTests {
    @Test func popupDrawsOverTheCommandPreviewOnItsOwnFill() throws {
        let project = Project(name: "Shellforge", path: "/tmp")
        var draft = TaskDraft(baseBranch: "main", agentId: "claude", model: "opus", reasoning: nil)
        draft.promptText = "One\nTwo\n/s"
        let opus = AgentModel(id: "opus", label: "Opus", detail: nil, efforts: [], defaultEffort: nil)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("layering-\(UUID().uuidString)")
        let model = NewTaskModel(project: project, agents: AgentPresets.all, available: ["claude"], draft: draft, rememberedModels: [:],
                                 catalogue: { _ in [opus] }, branches: { ["main"] }, submit: { _ in }, home: home)
        let host = NSHostingView(rootView: NewTaskSheet(model: model, dismiss: {}).seeded(step: 3))
        host.frame = NSRect(x: 0, y: 0, width: Sheet.width, height: Sheet.height)
        let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        // The sheet's catalogue load closes the popup when it lands; open it after that.
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        let rows = SkillCatalog.matchLimit
        let completions = model.completions
        completions.visible = (0..<rows).map { AgentCompletion(name: "skill-\($0)", kind: .skill, detail: nil, source: .user) }
        completions.anchor = CGPoint(x: Space.snug, y: 64)
        completions.fieldWidth = Sheet.width - 2 * Space.margin
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()

        let editor = try #require(descendant(of: NSScrollView.self, in: host) { $0.documentView is NSTextView })
        let field = host.convert(editor.bounds, from: editor)
        let top = field.minY + completions.anchor.y
        let height = CGFloat(rows) * Size.menuRow + 2 * Space.tight
        // The panel's own padding, between its hairline and the rows: no glyph and no row highlight
        // reach it — the pointer, wherever it is, moves the highlight — so only the fill shows.
        let x = field.minX + completions.anchor.x + (1 + Space.tight) / 2
        #expect(top + height > field.maxY + 100, "the popup must hang well past the field to test anything")

        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        func pixel(_ x: CGFloat, _ y: CGFloat) throws -> NSColor {
            try #require(bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB))
        }
        // Measured against each other, not against `Palette.menu` resolved in-process: an
        // offscreen test window composites the window colours lighter than they resolve, and shades
        // them by a few steps down the popup. What used to cover it — the command preview's
        // `codeBackground`, the caption's glyphs — sits twenty and more steps off the fill.
        let middle = top + height / 2
        let fill = try pixel(x, middle)
        let sheet = try pixel(field.minX - Space.margin / 2, middle)
        #expect(!Self.matches(fill, sheet, within: 5), "the popup is the sheet's own colour: \(Self.hex(fill))")

        var y = top + Radius.panel
        var strays: [String] = []
        while y < top + height - Radius.panel {
            let sample = try pixel(x, y)
            if !Self.matches(sample, fill, within: 12) { strays.append("y=\(Int(y - top)) \(Self.hex(sample))") }
            y += 2
        }
        #expect(strays.isEmpty, "something draws over the popup's \(Self.hex(fill)) fill: \(strays.joined(separator: ", "))")
    }

    private static func matches(_ a: NSColor, _ b: NSColor, within steps: Double) -> Bool {
        let tolerance = steps / 255
        return abs(a.redComponent - b.redComponent) <= tolerance
            && abs(a.greenComponent - b.greenComponent) <= tolerance
            && abs(a.blueComponent - b.blueComponent) <= tolerance
    }

    private static func hex(_ c: NSColor) -> String {
        String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }

    private func descendant<T: NSView>(of type: T.Type, in view: NSView, where match: (T) -> Bool) -> T? {
        if let view = view as? T, match(view) { return view }
        for subview in view.subviews {
            if let found = descendant(of: type, in: subview, where: match) { return found }
        }
        return nil
    }
}
