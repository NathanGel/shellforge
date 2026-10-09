// Ported in spirit from AiTerm (app/Tests/AiTermTests/SidebarRowGeometryTests.swift), GPLv3, Laurens D'Hondt.
import AppKit
import SwiftUI
import Testing
@testable import ShellforgeCore
@testable import ShellforgeDesign
@testable import ShellforgeUI

/// One painter, one rectangle: a selected row and a hovered row draw their pill over the same box,
/// so selecting a hovered row never shows a wash beside the selection (AiTerm's
/// `selectionAndHoverPaintTheSamePill`, on a row alone rather than AiTerm's whole app).
@MainActor @Suite struct SidebarRowGeometryTests {
    /// The box of everything drawn that is not the sidebar's ground.
    private func paintedBox(selected: Bool, hovered: Bool) throws -> CGRect {
        let row = SelectableRow(selected: selected, activate: {}) { Text(" ").frame(maxWidth: .infinity) }
            .environment(\.rowHovered, hovered)
            .frame(width: Size.sidebarWidth)
            .background(Palette.sidebar)
        let host = NSHostingView(rootView: row)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        RunLoop.main.run(until: Date().addingTimeInterval(0.05)); host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
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
            .frame(width: Size.sidebarWidth)
            .background(Palette.sidebar)
        let host = NSHostingView(rootView: row)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(x: 0, y: 0, width: Size.sidebarWidth, height: host.fittingSize.height)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
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
        #expect(CGFloat(trailing) / scale > Size.sidebarWidth - Space.section - Size.slot, "the mark moved off the trailing edge")
    }
}
