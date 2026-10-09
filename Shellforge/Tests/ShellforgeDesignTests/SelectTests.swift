// Ported from AiTerm (app/Tests/AiTermUITests/SelectTests.swift), GPLv3, Laurens D'Hondt.
import Testing
import AppKit
import SwiftUI
@testable import ShellforgeDesign

@Suite @MainActor struct SelectTests {
    /// SwiftUI pushes the environment's control size onto a hosted `NSControl` after `makeNSView`,
    /// so a `.large` set there alone came back `.regular`: a 24 pt bezel centred in the 28 pt slot,
    /// 4 pt shorter than the `Input` beside it in `NewTaskSheet`.
    ///
    /// The bezel itself cannot be measured here: `swiftpm-testing-helper` draws with the older
    /// control metrics, in which even a bare `.large` pop-up paints 24 pt. The app does not.
    @Test func testThePopUpStaysLarge() throws {
        let host = Self.host(Select(values: ["feat", "fix"], selection: .constant("feat"), label: { $0 }))
        let button = try #require(host.firstSubview(of: NSPopUpButton.self))
        #expect(button.controlSize == .large)
    }

    /// Two models can share a label. `addItem(withTitle:)` drops a title already in the menu, which
    /// left the menu a row short and every later index pointing at the wrong value.
    @Test func equalTitlesEachGetARow() throws {
        let picked = Box(0)
        let host = Self.host(Select(values: [1, 2, 3], selection: Binding(get: { picked.value }, set: { picked.value = $0 }),
                                    label: { _ in "Opus" }))
        let button = try #require(host.firstSubview(of: NSPopUpButton.self))
        #expect(button.numberOfItems == 3)

        button.selectItem(at: 2)
        _ = button.sendAction(button.action, to: button.target)
        #expect(picked.value == 3)
    }

    /// A value's detail can change under the same title — a catalogue refresh rewords a model — and
    /// the tooltip has to follow it, not wait for a title to change.
    @Test func aTooltipFollowsItsDetail() throws {
        let catalogue = Catalogue()
        let host = Self.host(CatalogueSelect(catalogue: catalogue))
        let button = try #require(host.firstSubview(of: NSPopUpButton.self))
        #expect(button.item(at: 0)?.toolTip == "Fast")

        catalogue.detail = "Fastest"
        settle(host)
        #expect(host.firstSubview(of: NSPopUpButton.self) === button, "the pop-up was rebuilt rather than updated")
        #expect(button.item(at: 0)?.toolTip == "Fastest")
    }

    /// `.disabled(true)` around a `Select` has to reach the pop-up itself, or it stays live.
    @Test func aDisabledSelectCannotBeOpened() throws {
        let host = Self.host(Select(values: ["feat", "fix"], selection: .constant("feat"), label: { $0 }).disabled(true))
        let button = try #require(host.firstSubview(of: NSPopUpButton.self))
        #expect(!button.isEnabled)
    }

    private final class Box<T> { var value: T; init(_ value: T) { self.value = value } }

    private final class Catalogue: ObservableObject { @Published var detail = "Fast" }

    private struct CatalogueSelect: View {
        @ObservedObject var catalogue: Catalogue
        var body: some View {
            Select(values: ["haiku"], selection: .constant("haiku"), label: { $0 }, detail: { _ in catalogue.detail })
        }
    }

    private static func host(_ view: some View) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(view.frame(width: 120)))
        host.frame = NSRect(x: 0, y: 0, width: 120, height: Size.control)
        _ = window(hosting: host, orderFront: false)
        settle(host)
        return host
    }
}
