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
        // 2 pt inside the box's left edge, upward from a full corner radius above its foot.
        let x = Int(2 * Snapshot.scale), start = rep.pixelsHigh - 1 - Int(Radius.group * Snapshot.scale)
        let fill = try #require(rep.colorAt(x: x, y: start)?.usingColorSpace(.sRGB))
        var y = start
        while y > 0, let pixel = rep.colorAt(x: x, y: y - 1)?.usingColorSpace(.sRGB),
              abs(pixel.redComponent - fill.redComponent) < 0.002 { y -= 1 }
        let run = CGFloat(start - y) / Snapshot.scale
        #expect(run > 2 * oneRow - Space.margin, "one fill for \(run) pt; a row is \(oneRow) pt")
    }

    /// The rule between rows stops short of the box's right edge, as the native one does.
    @Test func theRowDividerStopsShortOfTheRightEdge() throws {
        let rep = try #require(Snapshot.bitmap(of: host(SettingsRowDivider().frame(height: 1))))
        let y = rep.pixelsHigh / 2
        let ground = try #require(rep.colorAt(x: 1, y: y)?.usingColorSpace(.sRGB)) // under the leading inset
        let rule = try #require(rep.colorAt(x: rep.pixelsWide / 2, y: y)?.usingColorSpace(.sRGB))
        let edge = try #require(rep.colorAt(x: rep.pixelsWide - 1 - Int(Space.block * Snapshot.scale) / 2, y: y)?.usingColorSpace(.sRGB))
        #expect(rule.redComponent != ground.redComponent, "the rule is drawn: \(rep.pixelsWide)×\(rep.pixelsHigh), rule \(rule), ground \(ground)")
        #expect(abs(edge.redComponent - ground.redComponent) < 0.002, "nothing in the last \(Space.block / 2) pt")
    }
}

