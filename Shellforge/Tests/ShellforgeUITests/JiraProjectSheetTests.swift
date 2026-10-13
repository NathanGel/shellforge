// Ported from AiTerm (app/Tests/AiTermTests/JiraProjectSheetTests.swift), GPLv3, Laurens D'Hondt.
import AppKit
import SwiftUI
import ShellforgeCore
import ShellforgeDesign
import Testing
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// The sheet edits the list of Jira projects linked to a project. It picks from every Jira project
/// the account can see — hundreds of them — so it searches rather than scrolls. These tests drive
/// the rendered field the way the ticket picker's do.
@MainActor
@Suite(.serialized) struct JiraProjectSheetTests {
    static let site = URL(string: "https://example.atlassian.net")!
    static let projects = [
        JiraProjectRef(id: "1", key: "PLT", name: "Platform", siteURL: site),
        JiraProjectRef(id: "2", key: "WEB", name: "Website", siteURL: site),
        JiraProjectRef(id: "3", key: "WEBX", name: "Website extras", siteURL: site),
    ]
    static let placeholder = "Add a Jira project by key or name"

    /// What `submit` was handed, and whether it was called at all — an empty list is a real answer,
    /// so the count matters as much as the value.
    final class Submissions {
        var calls: [[JiraProjectRef]] = []
    }

    struct Harness {
        let host: NSHostingView<JiraProjectSheet>
        let window: NSWindow
        let submissions: Submissions
    }

    /// Hosted in a window, waited on by sleeping: a test spinning the run loop while it holds the
    /// main actor starves the sheet's `.task`, so the load would never run. `seedProjects` writes
    /// the same `State` that load writes, for the cases about the picker rather than the load.
    private func harness(linked: [JiraProjectRef] = [], listOpen: Bool = false, seedProjects: Bool = false,
                         projects: [JiraProjectRef] = projects,
                         load: @escaping () async throws -> [JiraProjectRef] = { projects }) async throws -> Harness {
        let submissions = Submissions()
        let sheet = JiraProjectSheet(projectName: "shellforge", linked: linked, canSubmit: true,
                                     loadProjects: load,
                                     submit: { submissions.calls.append($0) }, dismiss: {})
            .seeded(projects: seedProjects ? projects : nil, open: listOpen)
        let host = NSHostingView(rootView: sheet)
        host.frame = NSRect(x: 0, y: 0, width: Sheet.width, height: Sheet.height)
        let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        try await pause()
        return Harness(host: host, window: window, submissions: submissions)
    }

    private func pause() async throws {
        try await Task.sleep(for: .milliseconds(150))
    }

    private func field(in host: NSView) -> NSTextField? {
        descendants(of: NSTextField.self, in: host).first { $0.placeholderString == Self.placeholder }
    }

    private func type(_ text: String, into field: NSTextField) {
        field.stringValue = text
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    private func send(_ selector: Selector, to field: NSTextField) -> Bool {
        field.delegate?.control?(field, textView: NSTextView(), doCommandBy: selector) ?? false
    }

    private func pressCommandReturn(_ h: Harness) async throws {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                                     windowNumber: h.window.windowNumber, context: nil, characters: "\r",
                                     charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        _ = h.window.performKeyEquivalent(with: event)
        try await pause()
    }

    @Test func typingNarrowsTheListSoReturnAddsTheMatchingProject() async throws {
        let h = try await harness(listOpen: true, seedProjects: true)
        defer { h.window.orderOut(nil) }
        let field = try #require(self.field(in: h.host))

        // "webx" matches one of the three projects; ⏎ takes the row the narrowed list highlights.
        type("webx", into: field)
        try await pause()
        #expect(send(#selector(NSResponder.insertNewline(_:)), to: field))
        try await pause()

        // A pick joins the list above the field, and the field stays for the next one.
        #expect(self.field(in: h.host) != nil)
        try await pressCommandReturn(h)
        #expect(h.submissions.calls == [[Self.projects[2]]])
    }

    /// A project picked here joins the ones already linked, after them.
    @Test func aPickIsAddedAfterTheLinkedProjects() async throws {
        let h = try await harness(linked: [Self.projects[0]], listOpen: true, seedProjects: true)
        defer { h.window.orderOut(nil) }
        let field = try #require(self.field(in: h.host))

        type("web", into: field)
        try await pause()
        #expect(send(#selector(NSResponder.insertNewline(_:)), to: field))
        try await pause()
        try await pressCommandReturn(h)

        #expect(h.submissions.calls == [[Self.projects[0], Self.projects[1]]])
    }

    @Test func savingWithoutAPickKeepsTheLinkedProjects() async throws {
        let h = try await harness(linked: [Self.projects[1], Self.projects[0]], seedProjects: true)
        defer { h.window.orderOut(nil) }

        try await pressCommandReturn(h)

        #expect(h.submissions.calls == [[Self.projects[1], Self.projects[0]]])
    }

    /// Nothing linked is a valid answer: New Task then searches every Jira project. The sheet does
    /// not preselect one — a project chosen by alphabet is not one the reader picked.
    @Test func anEmptyListMeansNoJiraProject() async throws {
        let h = try await harness(seedProjects: true)
        defer { h.window.orderOut(nil) }
        #expect(self.field(in: h.host) != nil)

        try await pressCommandReturn(h)

        #expect(h.submissions.calls == [[]])
    }

    /// ⎋ with the list open closes the list, not the sheet: an unlink made before it survives, and
    /// Save still hands it up.
    @Test func escapeClosesTheListBeforeTheSheet() async throws {
        let h = try await harness(linked: [Self.projects[0], Self.projects[1]], listOpen: true, seedProjects: true)
        defer { h.window.orderOut(nil) }
        #expect(listIsOpen(in: h.host))

        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: h.window.windowNumber, context: nil, characters: "\u{1b}",
                                      charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        _ = h.window.performKeyEquivalent(with: escape)
        try await pause()

        #expect(!listIsOpen(in: h.host))
        #expect(self.field(in: h.host) != nil, "the sheet is still up")
        try await pressCommandReturn(h)
        #expect(h.submissions.calls == [[Self.projects[0], Self.projects[1]]])
    }

    /// Without a connection the sheet says how to make one, the linked projects stay, and Save still
    /// hands them up: unlinking needs no Jira.
    @Test func withoutJiraTheSheetSaysHowAndStillSaves() async throws {
        let refusal = "Connect Jira in Settings to choose a Jira project."
        let h = try await harness(linked: [Self.projects[0]], load: { throw ActionUnavailable(refusal) })
        defer { h.window.orderOut(nil) }
        try await pressCommandReturn(h)
        #expect(h.submissions.calls == [[Self.projects[0]]])

        #expect(JiraProjectSheet.statusLine(loading: false, error: refusal, projects: [], linked: [Self.projects[0]])
                    == .init(text: refusal, tone: .warning))
        #expect(JiraProjectSheet.statusLine(loading: true, error: nil, projects: [], linked: [])
                    == .init(text: "Loading Jira projects…", tone: .secondary))
        #expect(JiraProjectSheet.statusLine(loading: false, error: nil, projects: [], linked: [])?.text
                    == "No Jira projects are available to this account.")
        #expect(JiraProjectSheet.statusLine(loading: false, error: nil, projects: Self.projects, linked: [])?.text
                    == "Leave this empty to show tickets from every Jira project.")
        #expect(JiraProjectSheet.statusLine(loading: false, error: nil, projects: Self.projects, linked: Array(Self.projects.prefix(2)))?.text
                    == "New tasks will show tickets from PLT and WEB.")
    }

    /// The project list hangs over the status line under its field, as the ticket list does: the
    /// status is the field's next line, and used to draw after the list.
    @Test func theProjectListDrawsOverItsStatusLine() async throws {
        let blank = (1...6).map { JiraProjectRef(id: "\($0)", key: String(repeating: "\u{200B}", count: $0), name: "", siteURL: Self.site) }
        let h = try await harness(listOpen: true, seedProjects: true, projects: blank, load: { blank })
        defer { h.window.orderOut(nil) }

        let field = try #require(self.field(in: h.host))
        let frame = h.host.convert(field.bounds, from: field)
        let fieldRect = NSRect(x: Space.margin, y: frame.minY - (Size.control - frame.height) / 2,
                               width: Sheet.width - 2 * Space.margin, height: Size.control)
        let bitmap = try #require(Snapshot.bitmap(of: h.host))
        let scale = CGFloat(bitmap.pixelsWide) / h.host.bounds.width
        func pixel(_ x: CGFloat, _ y: CGFloat) throws -> NSColor {
            try #require(bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB))
        }
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
        #expect(strays.isEmpty, "the status line draws over the project list: \(strays.prefix(6).joined(separator: ", "))")
    }

    /// Whether the list is open, asked as the rendered sheet answers it: an open list with rows
    /// takes ↓, a closed one hands it back.
    private func listIsOpen(in host: NSView) -> Bool {
        guard let field = field(in: host) else { return false }
        return send(#selector(NSResponder.moveDown(_:)), to: field)
    }

    private func descendants<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        var matches = view.subviews.compactMap { $0 as? T }
        for subview in view.subviews { matches += descendants(of: type, in: subview) }
        return matches
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
}
