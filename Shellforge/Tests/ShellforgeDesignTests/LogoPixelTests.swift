import AppKit
import Testing
@testable import ShellforgeDesign

/// Every vendor mark draws: an SVG that `NSImage(data:)` accepts can still rasterise to nothing on
/// some macOS, and a mark drawn blank is a vendor missing from its row. Each brand's image, and each
/// artwork's, is drawn into a bitmap and must cover a fair share of it.
@MainActor @Suite struct LogoPixelTests {
    /// The share of a 32 × 32 bitmap the mark covers: pixels at least half opaque.
    private func coverage(_ image: NSImage) throws -> Double {
        let side = 32
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                   bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        var covered = 0
        for x in 0..<side { for y in 0..<side where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) >= 0.5 { covered += 1 } }
        return Double(covered) / Double(side * side)
    }

    @Test(arguments: [Palette.claude, Palette.openai, Palette.grok, Palette.jira, Palette.gitlab, Palette.github, Palette.vscode])
    func everyBrandDraws(brand: Brand) throws {
        let image = try #require(Logos.image(brand: brand, fill: "#FFFFFF"), "\(brand) did not rasterise")
        #expect(try coverage(image) > 0.05, "\(brand) drew (almost) nothing")
    }

    @Test(arguments: [("tanuki", IconSource.gitlabTanuki), ("pi", IconSource.piBadge)])
    func everyArtworkDraws(name: String, source: IconSource) throws {
        guard case let .artwork(svg, _) = source else { Issue.record("\(name) is not artwork"); return }
        let image = try #require(Logos.image(svg: svg), "\(name) did not rasterise")
        #expect(try coverage(image) > 0.05, "\(name) drew (almost) nothing")
    }
}
