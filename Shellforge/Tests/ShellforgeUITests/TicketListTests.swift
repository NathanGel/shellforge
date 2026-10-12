import AppKit
import SwiftUI
import ShellforgeCore
import ShellforgeDesign
import Testing
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// New Task's ticket list hangs under its field, over the help text and the fields below. It
/// draws over all of them, and it closes as AiTerm's does: ⎋, a click past it, leaving the step.
@MainActor
@Suite(.serialized) struct TicketListTests {
    /// Tickets with nothing to draw but their mark: a key of zero-width spaces, no summary, no
    /// lane. What shows across a row is the row's own ground, or whatever draws over it.
    private static let blankTickets = (1...SearchPicker<JiraTicket, EmptyView, EmptyView>.visibleLimit).map {
        JiraTicket(key: String(repeating: "\u{200B}", count: $0), summary: "", description: nil, issueType: nil, status: nil, url: "")
    }

    private func model(tickets: [JiraTicket] = []) -> NewTaskModel {
        NewTaskModel(project: Project(name: "demo", path: "/tmp/demo"), agents: AgentPresets.all, available: ["claude"],
                     draft: TaskDraft(baseBranch: "main", agentId: "claude", model: "", reasoning: nil), rememberedModels: [:],
                     catalogue: { _ in [] }, branches: { ["main"] }, submit: { _ in },
                     searchIssues: { _ in tickets },
                     home: FileManager.default.temporaryDirectory.appendingPathComponent("tickets-home-\(UUID().uuidString)"))
    }

    /// Waits by sleeping, not by running the run loop: a test holding the main actor in
    /// `RunLoop.run` starves the sheet's own `.task`s, and the first search would never land.
    private func host(_ model: NewTaskModel) async throws -> (NSWindow, NSHostingView<NewTaskSheet>) {
        let host = NSHostingView(rootView: NewTaskSheet(model: model, dismiss: {}))
        host.frame = NSRect(x: 0, y: 0, width: Sheet.width, height: Sheet.height)
        let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    @Test func leavingTheTaskStepClosesTheTicketList() {
        let m = model()
        m.ticketsOpen = true
        NewTaskSheet.leave(step: 1, model: m)
        #expect(!m.ticketsOpen, "advancing with the list open would bring it back open, and focused, on Back")
    }

    @Test func aClickPastTheTicketListClosesIt() async throws {
        let m = model(tickets: Self.blankTickets)
        m.ticketsOpen = true
        let (window, host) = try await host(m)
        defer { window.orderOut(nil) }
        #expect(m.ticketsOpen)
        // The title band's empty right end: nothing there but the sheet's ground.
        let point = host.convert(NSPoint(x: host.bounds.maxX - Space.margin, y: Space.section + Space.tight), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!m.ticketsOpen)
    }

    /// The help text under the field is the field's next line: it used to draw after the list, so
    /// its words showed through the first rows.
    @Test func theTicketListDrawsOverItsHelpText() async throws {
        let m = model(tickets: Self.blankTickets)
        m.ticketsOpen = true
        let (window, host) = try await host(m)
        defer { window.orderOut(nil) }
        #expect(m.results.count == Self.blankTickets.count, "\(m.results.count) \(String(describing: m.searchError)) \(m.query)")

        let field = try #require(descendant(of: NSTextField.self, in: host) { $0.placeholderString == m.ticketPlaceholder })
        let frame = host.convert(field.bounds, from: field)
        let fieldRect = NSRect(x: Space.margin, y: frame.minY - (Size.control - frame.height) / 2,
                               width: Sheet.width - 2 * Space.margin, height: Size.control)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        func pixel(_ x: CGFloat, _ y: CGFloat) throws -> NSColor {
            try #require(bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB))
        }
        // The help line: just under the field, where the list's first rows hang. Each sampled line
        // is measured against the same row's far end, past where the help text's words stop.
        var strays: [String] = []
        var y = fieldRect.maxY + Space.snug
        while y < fieldRect.maxY + Space.snug + 12 {
            let ground = try pixel(fieldRect.maxX - Space.margin, y)
            var x = fieldRect.minX + 130
            while x < fieldRect.minX + 260 {
                let sample = try pixel(x, y)
                if !Self.matches(sample, ground, within: 12) { strays.append("(\(Int(x)),\(Int(y))) \(Self.hex(sample)) on \(Self.hex(ground))") }
                x += 1
            }
            y += 1
        }
        #expect(strays.isEmpty, "the help text draws over the ticket list: \(strays.prefix(6).joined(separator: ", "))")
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
