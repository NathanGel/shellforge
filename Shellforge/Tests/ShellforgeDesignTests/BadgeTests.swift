// Ported from AiTerm (app/Tests/AiTermUITests/BadgeTests.swift), GPLv3, Laurens D'Hondt.
import AppKit
import Testing
import SwiftUI
@testable import ShellforgeDesign

@MainActor
struct BadgeTests {
    @Test func theFillAnswersToTheSurface() {
        // Resting on the sidebar and resting on a selected row are different washes; the badge
        // reads that from the environment rather than taking a flag.
        #expect(Badge.fill(surface: .sidebar, hovered: false) == Palette.badge)
        #expect(Badge.fill(surface: .accent, hovered: false) == Palette.badgeSelected)
    }

    @Test func theFillStrengthensOnHover() {
        // Both buttons on a subtitle line answer to the pointer, on either surface.
        #expect(Badge.fill(surface: .sidebar, hovered: true) == Palette.badgeHovered)
        #expect(Badge.fill(surface: .accent, hovered: true) == Palette.badgeSelectedHovered)
    }

    @Test func aBoxedLabelTakesTheSurfaceInk() {
        #expect(Badge.labelInk(surface: .sidebar) == Surface.sidebar.ink)
        #expect(Badge.labelInk(surface: .accent) == Surface.accent.ink)
    }

    @Test func theIconTintTurnsWhiteOnlyOnTheAccent() {
        // A brand mark keeps its own vendor colour off the accent (nil tint, `Icon` falls back to
        // `brand.hex`) and turns plain white on a selected row, exactly like the label above.
        #expect(Badge.iconTint(surface: .sidebar) == nil)
        #expect(Badge.iconTint(surface: .hover) == nil)
        #expect(Badge.iconTint(surface: .sheet) == nil)
        #expect(Badge.iconTint(surface: .accent) == Palette.onAccent)
    }

    @Test func aStatusTintColoursTheIconOffTheAccentOnly() {
        // A Settings check chip inks its checkmark green or its warning amber. On a selected row
        // everything still turns white, so the override yields to the accent like the label does.
        #expect(Badge.iconTint(surface: .sheet, override: Palette.green) == Palette.green)
        #expect(Badge.iconTint(surface: .sidebar, override: Palette.amber) == Palette.amber)
        #expect(Badge.iconTint(surface: .accent, override: Palette.green) == Palette.onAccent)
    }

    @Test func aDiffReadsAsSignedCountsWithAnEmptySideLeftOut() {
        // The extended VS Code badge: `+12 −3`, a true minus sign rather than a hyphen. A side with
        // nothing to count is left out rather than drawn as `+0`, and a diff with neither side is
        // no diff at all — the badge falls back to its plain shape.
        #expect(Badge.Diff(added: 12, removed: 3).segments.map(\.text) == ["+12", "\u{2212}3"])
        #expect(Badge.Diff(added: 7, removed: 0).segments.map(\.text) == ["+7"])
        #expect(Badge.Diff(added: 0, removed: 4).segments.map(\.text) == ["\u{2212}4"])
        #expect(Badge.Diff(added: 0, removed: 0).isEmpty)
        #expect(!Badge.Diff(added: 1, removed: 0).isEmpty)
    }

    @Test func diffCountsAreGreenAndRedOffTheAccentOnly() {
        // Additions green, removals red, on every ground but a selected row — where, like the icon
        // and the label, both turn the surface's own white.
        #expect(Badge.diffInk(surface: .sidebar, side: .added) == Palette.diffAdded)
        #expect(Badge.diffInk(surface: .hover, side: .removed) == Palette.diffRemoved)
        #expect(Badge.diffInk(surface: .accent, side: .added) == Surface.accent.ink)
        #expect(Badge.diffInk(surface: .accent, side: .removed) == Surface.accent.ink)
    }

    @Test func aQuietBadgeHasNoBoxUntilHovered() {
        // The sidebar rows' badges: no wash at rest, so the subtitle line reads as one line of text
        // rather than a row of boxes; under the pointer the same wash a boxed badge hovers to.
        #expect(Badge.fill(surface: .sidebar, hovered: false, style: .quiet) == .clear)
        #expect(Badge.fill(surface: .accent, hovered: false, style: .quiet) == .clear)
        #expect(Badge.fill(surface: .sidebar, hovered: true, style: .quiet) == Surface.sidebar.badgeWashHovered)
        #expect(Badge.fill(surface: .accent, hovered: true, style: .quiet) == Surface.accent.badgeWashHovered)
    }

    @Test func aQuietLabelTakesTheSecondaryInk() {
        // With no box behind it, the label sits back from the row title in secondary ink, on the
        // accent too.
        #expect(Badge.labelInk(surface: .sidebar, style: .quiet) == Surface.sidebar.secondaryInk)
        #expect(Badge.labelInk(surface: .accent, style: .quiet) == Surface.accent.secondaryInk)
    }

    /// A badge in a scaled sidebar is a scaled chip: its height, padding and icon all grow together.
    @Test func aBadgeIsAChipAtItsScale() {
        for scale in InterfaceScale.all {
            let host = NSHostingView(rootView: Badge("SHOP-412", icon: .brand(Palette.jira)).fixedSize().interfaceScale(scale))
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.height == scale(Size.chip), "at ×\(scale.factor)")
        }
    }

    /// A diff is drawn whatever else the badge carries. With no icon it used to fall through every
    /// branch: a diff alone drew nothing, and a label beside it drew the label alone.
    @Test func aDiffIsDrawnWithoutAnIcon() {
        let diff = Badge.Diff(added: 12, removed: 3)
        #expect(Self.width(Badge(diff: diff)) > 0)
        #expect(Self.width(Badge("main", diff: diff)) > Self.width(Badge("main")))
    }

    /// A badge that opens a menu is the same chip as one that runs an action: the menu adds no
    /// bezel, no indicator and no padding of its own, at any scale.
    @Test func aMenuBadgeIsTheSameChipAsAButtonBadge() {
        for scale in InterfaceScale.all {
            let button = Self.size(Badge("3", icon: .brand(Palette.jira), style: .quiet, action: {}), scale)
            let menu = Self.size(Badge("3", icon: .brand(Palette.jira), style: .quiet, menu: { Button("SHOP — Storefront") {} }), scale)
            #expect(menu == button, "at ×\(scale.factor)")
        }
    }

    private static func width(_ badge: Badge) -> CGFloat {
        let host = NSHostingView(rootView: badge)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.width
    }

    private static func size(_ badge: Badge, _ scale: InterfaceScale) -> CGSize {
        let host = NSHostingView(rootView: badge.interfaceScale(scale))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }
}
