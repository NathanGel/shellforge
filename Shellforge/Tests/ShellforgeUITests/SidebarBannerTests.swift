import SwiftUI
import Testing
@testable import ShellforgeDesign
@testable import ShellforgeUI

/// Banners are inline notices: a symbol in the tone's colour, the text, and for errors the ×, on a
/// tinted ground.
@MainActor @Suite struct SidebarBannerTests {
    @Test func eachToneHasItsSymbol() {
        #expect(SidebarBanner.symbol(for: .error) == "xmark.octagon.fill")
        #expect(SidebarBanner.symbol(for: .warning) == "exclamationmark.triangle.fill")
        #expect(SidebarBanner.symbol(for: .info) == "info.circle.fill")
    }

    @Test func eachToneHasAGround() {
        #expect(SidebarBanner.ground(for: .error) == Palette.noticeError)
        #expect(SidebarBanner.ground(for: .warning) == Palette.noticeWarning)
        #expect(SidebarBanner.ground(for: .info) == Palette.noticeInfo)
    }

    @Test func bannerKeepsItsDismiss() {
        var dismissed = false
        let banner = SidebarBanner(text: "x", tone: .error, dismiss: { dismissed = true })
        banner.dismiss?()
        #expect(dismissed)
    }
    /// Review fix: a warning's text is the normal text colour; the amber is the symbol's, as amber
    /// text on a light ground reads at about 2:1.
    @Test func aWarningsTextIsNormalInk() {
        #expect(SidebarBanner.textInk(for: .warning) == Palette.text)
        #expect(SidebarBanner.symbolInk(for: .warning) == Palette.amber)
    }
}
