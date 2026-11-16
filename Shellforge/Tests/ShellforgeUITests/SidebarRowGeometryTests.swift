// Ported in spirit from AiTerm (app/Tests/AiTermTests/SidebarRowGeometryTests.swift), GPLv3, Laurens D'Hondt.
import AppKit
import SwiftUI
import Testing
@testable import ShellforgeTestSupport
@testable import ShellforgeCore
@testable import ShellforgeDesign
@testable import ShellforgeUI

/// One painter, one rectangle: a selected row and a hovered row draw their pill over the same box,
/// so selecting a hovered row never shows a wash beside the selection (AiTerm's
/// `selectionAndHoverPaintTheSamePill`, on a row alone rather than AiTerm's whole app).
@MainActor @Suite struct SidebarRowGeometryTests {
    /// The Sessions panel's width at the sidebar's default: beside the activity bar.
    private let panelWidth = Size.sidebarWidth - ActivityBar.width(.standard)

    /// The box of everything drawn that is not the sidebar's ground.
    private func paintedBox(selected: Bool, hovered: Bool) throws -> CGRect {
        // In a sidebar list, as the sidebar draws it: the pill is the row's own background.
        let row = List {
            SelectableRow(selected: selected, activate: {}) { Text(" ").frame(maxWidth: .infinity) }
                .environment(\.rowHovered, hovered)
        }
        .listStyle(.sidebar).scrollContentBackground(.hidden).background(NativeRowHighlight.off)
        .frame(width: panelWidth, height: 80)
        .background(Palette.sidebar)
        let host = NSHostingView(rootView: row)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(origin: .zero, size: NSSize(width: panelWidth, height: 80))
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        RunLoop.main.run(until: Date().addingTimeInterval(0.05)); host.layoutSubtreeIfNeeded()
        let bitmap = try #require(Snapshot.bitmap(of: host))
        let ground = try #require(bitmap.colorAt(x: 1, y: 1))
        var box = CGRect.null
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let c = bitmap.colorAt(x: x, y: y), c != ground else { continue }
                box = box.union(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return box
    }

    @Test func selectionAndHoverPaintTheSamePill() throws {
        let selected = try paintedBox(selected: true, hovered: false)
        let hovered = try paintedBox(selected: false, hovered: true)
        #expect(!selected.isNull && !hovered.isNull)
        #expect(selected == hovered, "selected \(selected), hovered \(hovered)")
    }

    /// A title and branch far too long for the column: they truncate, and the status mark keeps its
    /// place at the row's trailing edge.
    @Test func aLongTitleAndBranchLeaveTheStatusMarkInPlace() throws {
        let long = String(repeating: "a-very-long-name-", count: 12)
        let task = TaskItem(projectId: UUID(), title: long, branch: long, worktreePath: "/w", baseBranch: "main")
        let row = TaskRowView(node: TaskNode(task: task, tabs: []), selected: false, agents: [.claude],
                              status: .needsInput, activate: {})
            .frame(width: panelWidth)
            .background(Palette.sidebar)
        let host = NSHostingView(rootView: row)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(x: 0, y: 0, width: panelWidth, height: host.fittingSize.height)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(Snapshot.bitmap(of: host))
        // The amber dot: strongly orange pixels.
        var xs: [Int] = []
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.redComponent > 0.8, c.greenComponent > 0.35, c.greenComponent < 0.75, c.blueComponent < 0.3 { xs.append(x) }
            }
        }
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        let trailing = try #require(xs.max(), "no status mark drawn")
        #expect(CGFloat(trailing) / scale > panelWidth - Space.section - Size.slot, "the mark moved off the trailing edge")
    }

    /// A row whose badges alone are wider than the column — a ticket, a five-digit diff, a long
    /// branch — at the narrowest panel and the largest text size: the badges give way, and the
    /// status mark is drawn whole inside the row.
    @Test(arguments: InterfaceScale.all)
    func wideBadgesLeaveTheStatusMarkInsideTheRow(scale interfaceScale: InterfaceScale) throws {
        let width = Size.sidebarMinWidth - ActivityBar.width(.standard) - 2 * SidebarRowLayout.listInset
        let task = TaskItem(projectId: UUID(), title: "Make the importer resumable after a crash",
                            branch: "feature/ABC-1234-make-the-importer-resumable", worktreePath: "/w",
                            baseBranch: "main", jira: JiraRef(key: "ABC-1234", summary: "", url: ""))
        let row = TaskRowView(node: TaskNode(task: task, tabs: []), selected: false, agents: [.claude],
                              status: .needsInput, activate: {}, diff: DiffStat(added: 17387, removed: 2705))
            .interfaceScale(interfaceScale)
            .frame(width: width)
            .background(Palette.sidebar)
        let host = NSHostingView(rootView: row)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(x: 0, y: 0, width: width, height: host.fittingSize.height)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(Snapshot.bitmap(of: host))
        var xs: [Int] = []
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.redComponent > 0.8, c.greenComponent > 0.35, c.greenComponent < 0.75, c.blueComponent < 0.3 { xs.append(x) }
            }
        }
        let pixels = CGFloat(bitmap.pixelsWide) / host.bounds.width
        let leading = try #require(xs.min(), "no status mark drawn")
        let trailing = try #require(xs.max())
        let drawn = CGFloat(trailing - leading + 1) / pixels
        // Whole: as wide as the mark is drawn, not cut off by the row's edge.
        #expect(drawn >= interfaceScale(Size.statusMark) - 1, "the mark is cut: \(drawn) pt drawn")
        #expect(CGFloat(trailing) / pixels <= width - interfaceScale(Space.base) + 1, "the mark runs past the row's padding")
    }
}
