import AppKit
import SwiftUI
import Testing
@testable import ShellforgeTestSupport
import ShellforgeDesign
@testable import ShellforgeUI

/// The row pill is the rectangle macOS itself selects and rings: a right-click draws its blue ring
/// around that rectangle, so a pill of any other shape had the ring falling outside it.
@MainActor @Suite struct RowPillFitTests {
    @Test func aSelectedRowsPillIsTheNativeSelectionRectangle() throws {
        let list = List {
            SelectableRow(selected: true, activate: {}) { Text("Mirai Bullhorn parsing in JarvisRAG").padding(.leading, 20) }
            Text("next")
        }
        .listStyle(.sidebar).scrollContentBackground(.hidden).background(NativeRowHighlight.off)
        .frame(width: 300, height: 120).background(Color.black)
        let host = NSHostingView(rootView: list)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame.size = NSSize(width: 300, height: 120)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        defer { window.close() }
        func rowViews(_ view: NSView) -> [NSView] { (view is NSTableRowView ? [view] : []) + view.subviews.flatMap(rowViews) }
        let row = try #require(rowViews(host).first.map { $0.convert($0.bounds, to: host) })
        let native = row.insetBy(dx: SidebarRowLayout.highlightInset, dy: 0)
        let rep = try #require(Snapshot.bitmap(of: host))
        func pill(_ x: CGFloat, _ y: CGFloat) -> Bool {
            guard let c = rep.colorAt(x: Int(x * Snapshot.scale), y: Int(y * Snapshot.scale))?.usingColorSpace(.sRGB) else { return false }
            // The accent in a key window, the inactive selection's grey otherwise: either way not the
            // black ground.
            return c.brightnessComponent > 0.12
        }
        // Just inside each edge of the native rectangle: the pill; just outside its sides: not.
        #expect(pill(native.minX + 2, row.midY), "leading edge")
        #expect(pill(native.maxX - 2, row.midY), "trailing edge")
        #expect(pill(native.midX, row.minY + 1.5), "top edge")
        #expect(pill(native.midX, row.maxY - 1.5), "bottom edge")
        #expect(!pill(native.minX - 2, row.midY), "nothing left of it")
    }

    /// The inset is the system's: a sidebar list's own selection, measured.
    @Test func theHighlightInsetIsTheNativeSelections() throws {
        let list = List(selection: .constant(Set([1]))) { Text("one").tag(1); Text("two").tag(2) }
            .listStyle(.sidebar).scrollContentBackground(.hidden).frame(width: 300, height: 100).background(Color.black)
        let host = NSHostingView(rootView: list)
        host.frame.size = NSSize(width: 300, height: 100)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        defer { window.close() }
        let rep = try #require(Snapshot.bitmap(of: host))
        // At the selection's mid-height, clear of its rounded corners.
        let rows = (0..<rep.pixelsHigh).map { y in
            (0..<rep.pixelsWide).filter { x in (rep.colorAt(x: x, y: y)?.brightnessComponent ?? 0) > 0.15 }
        }.filter { $0.count > 200 }
        let middle = try #require(rows.isEmpty ? nil : rows[rows.count / 2])
        let leading = CGFloat(try #require(middle.first)) / Snapshot.scale
        #expect(abs(leading - SidebarRowLayout.highlightInset) <= 1, "macOS insets its selection by \(leading) pt")
    }
}

