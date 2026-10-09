// Ported from AiTerm (app/Tests/AiTermUITests/SymbolMarkTests.swift), GPLv3, Laurens D'Hondt.
import AppKit
import SwiftUI
import Testing
@testable import ShellforgeDesign

@MainActor
struct SymbolMarkTests {
    private func host(_ view: some View) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(view.background(Color.black)))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// The mark is exactly the square it is given, at a Settings card's size and at the sidebar's.
    @Test(arguments: [Size.control, Size.vendorMark])
    func theMarkIsTheSizeItIsGiven(size: CGFloat) {
        let fitting = host(SymbolMark(symbol: "personalhotspot", size: size)).fittingSize
        #expect(abs(fitting.width - size) < 0.5 && abs(fitting.height - size) < 0.5)
    }

    /// The disc is `controlActive`: a point inside the disc but outside the half-size glyph is it.
    @Test func theDiscIsControlActive() throws {
        let host = host(SymbolMark(symbol: "personalhotspot", size: 28))
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        let sample = try #require(bitmap.colorAt(x: Int(5 * scale), y: Int(14 * scale))?.usingColorSpace(.sRGB))
        // Resolved as `ColorProbe` resolves: `controlActive` is a dynamic colour, light outside
        // `.darkAqua`.
        var resolved: NSColor?
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            resolved = NSColor(Palette.controlActive).usingColorSpace(.sRGB)
        }
        let disc = try #require(resolved)
        #expect(abs(sample.redComponent - disc.redComponent) < 0.03)
        #expect(abs(sample.greenComponent - disc.greenComponent) < 0.03)
    }

    /// `.paper` is the vendor discs' recipe: `markInk` on `markPaper`, the Mac's mark in the footer
    /// and on its Settings card. The disc reads as white.
    @Test func thePaperDiscIsMarkPaper() throws {
        let host = host(SymbolMark(symbol: "macbook", size: 28, style: .paper))
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        let sample = try #require(bitmap.colorAt(x: Int(5 * scale), y: Int(14 * scale))?.usingColorSpace(.sRGB))
        #expect(sample.redComponent > 0.97 && sample.greenComponent > 0.97 && sample.blueComponent > 0.97)
    }
}
