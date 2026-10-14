import AppKit
import SwiftUI
import Testing
@testable import ShellforgeDesign

/// One place decides how a surface is translucent: macOS 26's glass, the sidebar material before it,
/// and an opaque colour whenever Reduce Transparency is on.
@MainActor @Suite struct ShellforgeMaterialTests {
    @Test func macOS26IsGlass() {
        #expect(ShellforgeMaterial.kind(macOSMajor: 26, reduceTransparency: false) == .glass)
        #expect(ShellforgeMaterial.kind(macOSMajor: 27, reduceTransparency: false) == .glass)
    }

    @Test func earlierIsTheSidebarMaterial() {
        for major in 12...15 {
            #expect(ShellforgeMaterial.kind(macOSMajor: major, reduceTransparency: false) == .sidebar)
        }
    }

    @Test func reduceTransparencyIsAlwaysOpaque() {
        for major in [12, 15, 26] {
            #expect(ShellforgeMaterial.kind(macOSMajor: major, reduceTransparency: true) == .opaque)
        }
    }

    @Test(arguments: [ShellforgeMaterial.Kind.glass, .sidebar, .opaque])
    func everyKindDraws(kind: ShellforgeMaterial.Kind) throws {
        let host = NSHostingView(rootView: MaterialBackground(RoundedRectangle(cornerRadius: Radius.control), kind: kind)
            .frame(width: 120, height: 80))
        host.frame = NSRect(x: 0, y: 0, width: 120, height: 80)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        #expect(rep.pixelsWide > 0)
    }
}
