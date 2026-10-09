// Ported from AiTerm (app/Tests/AiTermUITests/IconSourceTests.swift), GPLv3, Laurens D'Hondt.
import AppKit
import Testing
import SwiftUI
@testable import ShellforgeDesign

@MainActor
struct IconSourceTests {
    private static let brands = [Palette.claude, Palette.openai, Palette.jira, Palette.gitlab, Palette.github, Palette.vscode]

    /// A brand's mark is SVG built at runtime; if it will not decode, its fallback is all that is
    /// drawn, so a brand without one would vanish.
    @Test func everyBrandHasAFallback() {
        for brand in Self.brands { #expect(!brand.fallbackSymbol.isEmpty, "\(brand.path.prefix(12))… has no fallback") }
    }

    @Test func brandMarksAreDistinct() {
        // Two vendors sharing a mark means one of them is drawn wrong. Cheap to check, and the
        // kind of copy-paste error that is invisible in review.
        let paths = Self.brands.map(\.path)
        #expect(Set(paths).count == paths.count, "two brands share a mark path")
    }

    /// The tanuki and Pi's badge are drawn as whole documents. Both have to decode here, or every
    /// GitLab project tile and Pi avatar is quietly drawing its fallback instead.
    @Test func theFullColourMarksDecode() throws {
        for source in [IconSource.gitlabTanuki, .piBadge] {
            guard case let .artwork(svg, _) = source else { Issue.record("\(source) is not artwork"); continue }
            #expect(Logos.image(svg: svg) != nil)
        }
    }

    /// A symbol keeps its glyph's own width: the Settings check chips are measured by it, and a
    /// `size` × `size` frame once widened `! Driver` by six points and narrowed `✓ CLI`.
    @Test func aSymbolKeepsItsNaturalWidth() {
        func width(_ view: some View) -> CGFloat {
            let host = NSHostingView(rootView: view.fixedSize())
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.width
        }
        for name in ["exclamationmark", "checkmark"] {
            #expect(width(Icon(.symbol(name), size: 10)) == width(Image(systemName: name).font(.system(size: 10))), "\(name)")
        }
    }

    /// An untinted symbol inks for the surface it sits on: full white on the accent, the label ink
    /// (≈85 % white) anywhere else.
    @Test func anUntintedSymbolTakesTheSurfaceInk() throws {
        let onAccent = try #require(brightestPixel(of: Icon(.symbol("circle.fill"), size: 12).surface(.accent)))
        let onSheet = try #require(brightestPixel(of: Icon(.symbol("circle.fill"), size: 12).surface(.sheet)))
        #expect(onAccent.redComponent > 0.97)
        #expect(onSheet.redComponent < 0.9)
    }
}
