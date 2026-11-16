import AppKit
import SwiftUI
import Testing
@testable import ShellforgeTestSupport
@testable import ShellforgeCore
@testable import ShellforgeDesign
@testable import ShellforgeUI

/// The status-first sidebar's quieter rows: a divider's name leads its rule, and a tunnel in Sessions
/// is one line, its uptime in its tooltip.
@MainActor @Suite struct QuietRowsTests {
    private let width: CGFloat = 340

    private func host(_ view: some View) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(view.frame(width: width).background(Palette.sidebar)))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(x: 0, y: 0, width: width, height: max(host.fittingSize.height, 1))
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// The leftmost x of the brightest ink: the name's text.
    private func textLeading(_ host: NSHostingView<AnyView>) throws -> CGFloat {
        let bitmap = try #require(Snapshot.bitmap(of: host))
        var xs: [Int] = []
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.redComponent + c.greenComponent + c.blueComponent > 1.2 { xs.append(x) }
            }
        }
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        return CGFloat(try #require(xs.min(), "no text drawn")) / scale
    }

    @Test func aDividersNameLeadsItsRule() throws {
        let row = DividerRow(row: DividerRowItem(divider: SidebarDivider(name: "Client work", position: 1)), rename: {}, remove: {})
        #expect(try textLeading(host(row)) < width / 4)
    }

    @Test func anUpTunnelInSessionsIsOneLine() {
        var tunnel = TunnelRowItem(projectId: UUID(), alias: "db-tunnel", forwards: [], state: .up, error: nil, missing: false)
        tunnel.since = Date().timeIntervalSince1970 - 600
        let compact = host(TunnelRowView(row: tunnel, start: {}, stop: {}, compact: true))
        #expect(compact.fittingSize.height == Size.menuRow)
        // The SSH panel's keeps its uptime line.
        let full = host(TunnelRowView(row: tunnel, start: {}, stop: {}, offersRearrange: false))
        #expect(full.fittingSize.height > Size.menuRow)
    }

    @Test func aFailedTunnelInSessionsStillSaysWhy() {
        let tunnel = TunnelRowItem(projectId: UUID(), alias: "db-tunnel", forwards: [], state: .failed, error: "Connection refused", missing: false)
        #expect(host(TunnelRowView(row: tunnel, start: {}, stop: {}, compact: true)).fittingSize.height > Size.menuRow)
    }

    /// A project's chevron shows while it is folded or under the pointer, never for one with nothing to fold.
    @Test func theChevronShowsOnlyWhenItSaysSomething() {
        #expect(!ProjectHeaderRow.showsChevron(collapses: true, collapsed: false, hovered: false))
        #expect(ProjectHeaderRow.showsChevron(collapses: true, collapsed: false, hovered: true))
        #expect(ProjectHeaderRow.showsChevron(collapses: true, collapsed: true, hovered: false))
        #expect(!ProjectHeaderRow.showsChevron(collapses: false, collapsed: false, hovered: true))
    }
}
