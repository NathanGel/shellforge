// Ported from AiTerm (app/Tests/AiTermUITests/SidebarHeadingTests.swift), GPLv3, Laurens D'Hondt.
import AppKit
import SwiftUI
import Testing
@testable import ShellforgeDesign

@MainActor
struct SidebarHeadingTests {
    /// A sidebar heading grows with the sidebar, like every row it heads.
    @Test func itGrowsWithTheSidebar() {
        func size(_ scale: InterfaceScale) -> CGSize {
            let host = NSHostingView(rootView: SidebarHeading("Projects").fixedSize().interfaceScale(scale))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize
        }
        let standard = size(.standard), extraLarge = size(.extraLarge)
        #expect(extraLarge.height > standard.height)
        #expect(extraLarge.width > standard.width)
    }
    /// macOS 26 section headers are sentence case: the heading draws its title as given, so a lower-
    /// case divider name is not shouted.
    @Test func aHeadingIsNotUppercased() {
        func width(_ title: String) -> CGFloat { NSHostingView(rootView: SidebarHeading(title).fixedSize()).fittingSize.width }
        #expect(width("Projects") < width("PROJECTS"))
    }
}
