// Ported from AiTerm (app/Tests/AiTermUITests/LogosTests.swift), GPLv3, Laurens D'Hondt.
import AppKit
import Testing
@testable import ShellforgeDesign

@MainActor
struct LogosTests {
    /// A brand is its name: two brands are cached apart because they are called apart, however
    /// their path data starts, and the cache never hashes the path to tell.
    @Test func brandsThatStartAlikeAreCachedApart() {
        let prefix = "M0 0h24v24H0zM0 0h24v24H0z"
        let first = Logos.image(brand: Brand("first", 0xFFFFFF, path: prefix + "M2 2h4v4H2z", fallbackSymbol: "circle"), fill: "#FFFFFF")
        let second = Logos.image(brand: Brand("second", 0xFFFFFF, path: prefix + "M2 2h8v8H2z", fallbackSymbol: "circle"), fill: "#FFFFFF")
        #expect(first != nil && second != nil)
        #expect(first !== second)
    }

    @Test func aMarkIsRasterisedOncePerFill() {
        let brand = Palette.jira
        #expect(Logos.image(brand: brand, fill: "#2684FF") === Logos.image(brand: brand, fill: "#2684FF"))
        #expect(Logos.image(brand: brand, fill: "#2684FF") !== Logos.image(brand: brand, fill: "#FFFFFF"))
    }

    @Test func everyBrandHasItsOwnName() {
        let brands = [Palette.claude, Palette.jira, Palette.gitlab, Palette.github, Palette.vscode, Palette.openai, Palette.grok]
        #expect(Set(brands.map(\.name)).count == brands.count)
    }

    /// The tint a row paints a mark in is resolved once, then remembered: the same text again, and
    /// the right one.
    @Test func aTintIsResolvedToItsHexOnceAndRemembered() {
        #expect(Icon.hexString(Palette.markPaper) == "#FFFFFF")
        #expect(Icon.hexString(Palette.markInk) == "#000000")
        #expect(Icon.hexString(Palette.markPaper) == "#FFFFFF")
    }

    /// Two brands wrongly given one name are not drawn as each other, whatever their paths: the
    /// second here is as long as the first, which a key of the name and the path's length took for it.
    @Test func brandsSharingANameButNotAPathAreCachedApart() {
        for (one, other) in [("M0 0h24v24H0z", "M0 0h2v2H0z"), ("M0 0h24v24H0z", "M0 0h12v12H0z")] {
            let name = "same-\(UUID().uuidString)"
            let first = Logos.image(brand: Brand(name, 0xFFFFFF, path: one, fallbackSymbol: "circle"), fill: "#FFFFFF")
            let second = Logos.image(brand: Brand(name, 0xFFFFFF, path: other, fallbackSymbol: "circle"), fill: "#FFFFFF")
            #expect(first != nil && second != nil)
            #expect(first !== second, "\(other) was drawn as \(one)")
            #expect(Logos.image(brand: Brand(name, 0xFFFFFF, path: other, fallbackSymbol: "circle"), fill: "#FFFFFF") === second,
                    "still rasterised once")
        }
    }
}
