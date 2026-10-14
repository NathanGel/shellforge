import AppKit
import SwiftUI
import Testing
@testable import ShellforgeTestSupport
import ShellforgeDesign
@testable import ShellforgeUI

/// Settings as macOS's grouped form draws it: a section is one box, its cards rows inside it.
@MainActor @Suite struct SettingsSectionTests {
    private func row(_ title: String) -> some View {
        SettingsCard(title: title, status: SettingsStatus(.idle, "Idle")) { Color.clear } content: { Text("A field") }
    }

    private func host(_ view: some View) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(view.frame(width: 400).background(Palette.surface)))
        host.appearance = NSAppearance(named: .aqua)
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        return host
    }

    @Test func aSectionIsOneBoxAndItsCardsAreRowsInIt() throws {
        let oneRow = host(row("One")).fittingSize.height
        let rep = try #require(Snapshot.bitmap(of: host(SettingsSection("Core") {
            row("One")
            SettingsRowDivider()
            row("Two")
        })))
        // 2 pt inside the box's left edge, upward from 4 pt above its foot, clear of its corner.
        let x = Int(2 * Snapshot.scale), start = rep.pixelsHigh - 1 - Int(4 * Snapshot.scale)
        let fill = try #require(rep.colorAt(x: x, y: start)?.usingColorSpace(.sRGB))
        var y = start
        while y > 0, let pixel = rep.colorAt(x: x, y: y - 1)?.usingColorSpace(.sRGB),
              abs(pixel.redComponent - fill.redComponent) < 0.002 { y -= 1 }
        let run = CGFloat(start - y) / Snapshot.scale
        #expect(run > 2 * oneRow - Space.margin, "one fill for \(run) pt; a row is \(oneRow) pt")
    }
}
