// Ported from AiTerm (app/Tests/AiTermUITests/InterfaceScaleTests.swift), GPLv3, Laurens D'Hondt.
import AppKit
import SwiftUI
import Testing
@testable import ShellforgeDesign

@MainActor
struct InterfaceScaleTests {
    /// Default is Apple's own scale, untouched — including the fractional sizes a glyph derives
    /// from its diameter, which rounding would otherwise move by a pixel.
    @Test func standardIsTheIdentity() {
        for points: CGFloat in [Space.hairline, Space.inset, Size.row, Size.sidebarWidth, Radius.panel, 16 * 0.61, -5] {
            #expect(InterfaceScale.standard(points) == points)
        }
    }

    /// The steps land on whole points, so a 1x display draws every edge on a pixel.
    @Test func largerStepsRoundToWholePoints() {
        #expect(InterfaceScale.large(Size.row) == 60)
        #expect(InterfaceScale.extraLarge(Size.row) == 68)
        #expect(InterfaceScale.large(Size.sidebarMinWidth) == 414)
        #expect(InterfaceScale.extraLarge(Size.sidebarMinWidth) == 468)
        #expect(InterfaceScale.large(Size.chip) == 18)
        #expect(InterfaceScale.extraLarge(Size.chip) == 21)
        #expect(InterfaceScale.large(-5) == -6)
    }

    /// Body text lands on Apple's next two sizes up, and is not rounded: text must never grow
    /// faster than the whole-point layout around it.
    @Test func typeScalesWithoutRounding() {
        #expect(abs(Typography.body.scaled(by: .large).size - 15) < 0.1)
        #expect(abs(Typography.body.scaled(by: .extraLarge).size - 17) < 0.1)
        #expect(Typography.mono.scaled(by: .large).size == 11 * 1.15)
        #expect(Typography.mono.scaled(by: .large).design == .monospaced)
        #expect(Typography.micro.scaled(by: .large).weight == .semibold)
        #expect(Typography.body.scaled(by: .standard) == Typography.body)
    }

    /// `font(TypeStyle)` reads the environment, so a scaled subtree's text grows with no change
    /// at the call site.
    @Test func fontFollowsTheEnvironment() {
        func height(_ scale: InterfaceScale) -> CGFloat {
            let host = NSHostingView(rootView: Text("Mg").font(Typography.body).fixedSize().interfaceScale(scale))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        let standard = height(.standard), extraLarge = height(.extraLarge)
        #expect(extraLarge / standard > 1.2)
        #expect(extraLarge / standard < 1.4)
    }

    @Test func theEnvironmentDefaultsToStandard() {
        #expect(EnvironmentValues().interfaceScale == .standard)
    }
}
