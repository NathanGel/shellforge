// Ported from AiTerm (app/Tests/AiTermTests/SidebarFooterGeometryTests.swift), GPLv3, Laurens D'Hondt.
import AppKit
import SwiftUI
import ShellforgeDesign
import Testing
@testable import ShellforgeTestSupport
@testable import ShellforgeCore
@testable import ShellforgeUI

@MainActor
struct SidebarFooterGeometryTests {
    private let context = UsageLine(window: .context, percent: 84, reset: nil, warning: true)
    private let fiveHour = UsageLine(window: .fiveHour, percent: 84, reset: "16:40", warning: true)
    private let week = UsageLine(window: .weekly, percent: 84, reset: "Wed 16:28", warning: true)

    /// Each ring and number is hovered and read as its words — the glyphs alone say "wk", a ring
    /// and "Wed". SwiftUI builds no accessibility tree for a test, so the words are checked here, and
    /// the footer hands them to `.help` and `.accessibilityLabel` as they are.
    @Test func everyRingAndNumberIsReadInWords() {
        #expect(UsageLine(window: .weekly, percent: 61, reset: "Fri 23:33", warning: false, resetInFull: "Friday 23:33").help
                == "Weekly limit, 61 % used, resets Friday 23:33")
        #expect(fiveHour.help == "5-hour limit, 84 % used, resets 16:40")
        #expect(context.help == "Context 84 % full")
    }

    /// The Mac's readings row is read as its readings in words; before the first sample, as the Mac.
    @Test func theMacsReadingsAreReadInWords() {
        #expect(SidebarFooter.readingsLabel([]) == "Mac")
        #expect(SidebarFooter.readingsLabel([UsageLine(window: .cpu, percent: 23, warning: false),
                                             UsageLine(window: .ram, percent: 78, warning: true)])
                == "CPU 23 % busy, Memory 78 % used, under pressure")
    }

    /// A note's ink follows the row's `warning`, never its wording: the same words on a row that
    /// is not a warning stay muted.
    @Test func aNoteIsAmberOnlyWhenTheRowIsAWarning() {
        #expect(SidebarFooter.noteInk(UsageVendorRow(vendor: .claude, lines: [], note: "Usage disconnected", warning: true)) == Palette.amber)
        #expect(SidebarFooter.noteInk(UsageVendorRow(vendor: .claude, lines: [], note: "Usage disconnected")) == Palette.muted)
        #expect(SidebarFooter.noteInk(UsageVendorRow(vendor: .codex, lines: [], note: "Reconnecting", warning: true)) == Palette.amber)
    }

    private func host(_ rows: [UsageVendorRow], task: UsageTaskRow? = nil, machine: [UsageLine] = [], mode: MacMode = .desk,
                      width: CGFloat = Size.sidebarMinWidth, scale: InterfaceScale = .standard) -> NSHostingView<AnyView> {
        let mac = MacModePresentation.line(mode: mode, hotspot: "Laurens’s iPhone", wifi: "Office-WiFi")
        let view = AnyView(SidebarFooter(task: task, rows: rows, machine: machine, mac: mac)
            .interfaceScale(scale)
            .frame(width: width, alignment: .leading)
            .background(Color.black))
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(x: 0, y: 0, width: width, height: host.fittingSize.height)
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// The USAGE group: its heading and one `Size.menuRow` line per provider, even when a provider
    /// reports every segment, inside the group's `Space.tight` above and `Space.base` below — 84 pt
    /// for two providers. The ring is round ink inside the row, not a reason for it to grow.
    @Test func everyProviderUsesOneLine() {
        let rows = [
            UsageVendorRow(vendor: .claude, lines: [week, fiveHour], note: nil),
            UsageVendorRow(vendor: .codex, lines: [week, fiveHour], note: nil),
        ]
        // SYSTEM's heading and the Mac's readings, the rule, then USAGE's heading and two providers.
        let expected = (Space.tight + Size.menuRow * 2 + Space.base) + 1 + (Space.tight + Size.menuRow * 3 + Space.base)
        #expect(abs(host(rows).fittingSize.height - expected) < 0.5)
    }

    /// With a task selected the context row adds one line to SYSTEM.
    @Test func theTaskRowAddsOneLineAndARule() {
        let rows = [
            UsageVendorRow(vendor: .claude, lines: [week, fiveHour], note: nil),
            UsageVendorRow(vendor: .codex, lines: [week], note: nil),
        ]
        let task = UsageTaskRow(agent: .claude, context: context)
        let usage = Space.tight + Size.menuRow * 3 + Space.base
        // SYSTEM's heading, the context row and the Mac's readings, then the rule.
        let expected = usage + Space.tight + Size.menuRow * 3 + Space.base + 1
        #expect(abs(host(rows, task: task).fittingSize.height - expected) < 0.5)
    }

    /// The context row is a vendor row with one window labelled `ctx`: mark, ring and number,
    /// packed against the leading edge exactly as a vendor's `wk` is, not pushed to the trailing edge, and with no title or avatar group beside it.
    @Test func theTaskRowDrawsOnlyItsMarkAndContext() throws {
        let host = host([], task: UsageTaskRow(agent: .claude, context: context), width: 600)
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let label = ("ctx " as NSString).size(withAttributes: [.font: font]).width
        let text = (" 84%" as NSString).size(withAttributes: [.font: font]).width
        let expected = SidebarRowLayout.listInset + Space.base + Size.vendorMark + Space.inset + label + Size.statusMark + text
        // Below the SYSTEM heading, above the rule: the context row alone.
        let top = Int(Space.tight + Size.menuRow)
        let right = try paintedWidth(host, band: top..<(top + Int(Size.menuRow)))
        #expect(abs(right - expected) < 2,
                "the task row's ink ends at \(right) pt; a mark and one ctx segment end at \(expected) pt")
    }

    /// The ring replaced a four-cell text bar, so nothing in the row's *text* proves it is there.
    /// Measure the gap between the painted row and the width of its text alone: what is left over
    /// is the ring, and it has to be a ring's worth.
    @Test func eachSegmentDrawsARingBesideItsNumber() throws {
        let rows = [UsageVendorRow(vendor: .claude, lines: [week.withoutReset], note: nil)]
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let text = ("wk  84%" as NSString).size(withAttributes: [.font: font]).width
        // The row also carries the vendor mark and the footer's leading edge: the list's inset
        // plus a row's `Space.base`.
        let leading = SidebarRowLayout.listInset + Space.base + Size.vendorMark + Space.inset
        let ring = try paintedWidth(rows, width: 600) - leading - text
        #expect(abs(ring - Size.statusMark) < 2,
                "the segment leaves \(ring) pt for its ring; a ring is \(Size.statusMark) pt")
    }

    /// Every telemetry segment constructs the same ring component at the shared status-mark
    /// diameter. Percent and warning state may change its fill and colour, never its size.
    @Test func everyTelemetryRingHasTheSameDiameter() {
        let sizes = [
            UsageRing(percent: 23, warning: false, size: Size.statusMark),
            UsageRing(percent: 84, warning: true, size: Size.statusMark),
            UsageRing(percent: 42, warning: false, size: Size.statusMark),
        ].map { NSHostingView(rootView: $0).fittingSize }
        #expect(sizes.allSatisfy { abs($0.width - Size.statusMark) < 0.5 })
        #expect(sizes.allSatisfy { abs($0.height - Size.statusMark) < 0.5 })
    }

    /// The reset time is the row's only source of "when does this clear?", so it has to be drawn,
    /// not merely carried on the line. Dropping it from the renderer narrows the row by exactly the
    /// width of the two reset strings.
    @Test func theRowDrawsEachWindowsResetTime() throws {
        let bare = [UsageVendorRow(vendor: .claude,
                                   lines: [fiveHour.withoutReset, week.withoutReset], note: nil)]
        let dated = [UsageVendorRow(vendor: .claude, lines: [week, fiveHour], note: nil)]
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let resets = (" \(fiveHour.reset!) \(week.reset!)" as NSString).size(withAttributes: [.font: font]).width
        let grown = try paintedWidth(dated, width: 600) - paintedWidth(bare, width: 600)
        #expect(abs(grown - resets) < 2,
                "reset times add \(grown) pt of row; the two strings measure \(resets) pt")
    }

    /// The sidebar minimum exists to fit this row. The common case — both windows under 100%, the
    /// 5-hour one resetting today and the weekly one on a later day — must paint inside
    /// ``Size/sidebarMinWidth`` rather than truncate.
    /// At every interface size, against that size's own minimum.
    @Test(arguments: InterfaceScale.all)
    func theTwoWindowTelemetryFitsTheMinimumSidebarWidth(scale: InterfaceScale) throws {
        let rows = [UsageVendorRow(vendor: .claude, lines: [week, fiveHour], note: nil)]
        // Comparing the row against its own unconstrained rendering is the only honest test:
        // arithmetic on the string's width agrees to a fraction of a point and still truncates.
        let natural = try paintedWidth(rows, width: 900, scale: scale)
        let minimum = scale(Size.sidebarMinWidth)
        let atMinimum = try paintedWidth(rows, width: minimum, scale: scale)
        #expect(abs(atMinimum - natural) < 1,
                "at ×\(scale.factor) the row paints \(natural) pt unconstrained but only \(atMinimum) pt at the \(minimum) pt sidebar minimum, so it is truncating")
    }

    private let counts = TokenTally(input: 936_018, cached: 935_988, output: 5_625)

    /// What SwiftUI lays out for text drawn as separate `Text` runs: each run's advance is rounded up
    /// to a whole point, so five runs set up to four points wider than the same glyphs as one
    /// string (measured: `in 936k · out 5.6k` is 122.4 pt as one string and 125 pt as the footer's
    /// five runs). The counts are drawn in runs, for their inks, so the expectation is the runs'.
    private func laidOut(_ runs: [String]) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        return runs.map { ($0 as NSString).size(withAttributes: [.font: font]).width.rounded(.up) }.reduce(0, +)
    }

    /// The counts ride on the context row: SYSTEM is as tall with them as without.
    @Test func theCountsShareTheContextRow() {
        let with = host([], task: UsageTaskRow(agent: .claude, context: context, tokens: counts)).fittingSize.height
        let without = host([], task: UsageTaskRow(agent: .claude, context: context)).fittingSize.height
        #expect(abs(with - without) < 0.5)
    }

    /// After the ring and the fill come ` · in 936k · out 5.6k`, in the row's own run: no gap opens
    /// between `ctx` and the counts, and the counts draw no ring of their own.
    @Test func theCountsFollowTheContextInItsRun() throws {
        let host = host([], task: UsageTaskRow(agent: .claude, context: context, tokens: counts), width: 600)
        let text = laidOut(["ctx ", " 84%", " · ", "in ", "936k", " · ", "out ", "5.6k"])
        let expected = SidebarRowLayout.listInset + Space.base + Size.vendorMark + Space.inset + text + Size.statusMark
        let top = Int(Space.tight + Size.menuRow)
        let right = try paintedWidth(host, band: top..<(top + Int(Size.menuRow)))
        #expect(abs(right - expected) < 2, "the row's ink ends at \(right) pt; ctx and the counts end at \(expected) pt")
    }

    /// An agent can report its spend before its window (Grok, until it knows the model): the counts
    /// then stand alone, with no separator in front and no "No context yet".
    @Test func theCountsStandAloneBeforeAContext() throws {
        let host = host([], task: UsageTaskRow(agent: .grok, context: nil, tokens: counts), width: 600)
        let text = laidOut(["in ", "936k", " · ", "out ", "5.6k"])
        let expected = SidebarRowLayout.listInset + Space.base + Size.vendorMark + Space.inset + text
        let top = Int(Space.tight + Size.menuRow)
        let right = try paintedWidth(host, band: top..<(top + Int(Size.menuRow)))
        #expect(abs(right - expected) < 2, "the row's ink ends at \(right) pt; the counts alone end at \(expected) pt")
    }

    /// The widest context row — a full window and both counts at their widest — paints whole at the
    /// sidebar's narrowest, at every size.
    @Test(arguments: InterfaceScale.all)
    func theWidestContextRowFitsTheMinimumSidebarWidth(scale: InterfaceScale) throws {
        let task = UsageTaskRow(agent: .claude, context: UsageLine(window: .context, percent: 100, reset: nil, warning: true),
                                tokens: TokenTally(input: 999_999, cached: 0, output: 999_999))
        let top = Int(scale(Space.tight) + scale(Size.menuRow))
        let band = top..<(top + Int(scale(Size.menuRow)))
        let natural = try paintedWidth(host([], task: task, width: 900, scale: scale), band: band)
        let atMinimum = try paintedWidth(host([], task: task, width: scale(Size.sidebarMinWidth), scale: scale), band: band)
        #expect(abs(atMinimum - natural) < 1,
                "at ×\(scale.factor) the ctx row paints \(natural) pt unconstrained but only \(atMinimum) pt at the minimum")
    }}

private extension UsageLine {
    var withoutReset: UsageLine { UsageLine(window: window, percent: percent, reset: nil, warning: warning) }
}

extension SidebarFooterGeometryTests {
    /// The footer stretches to its container and its text leaves are not separate `NSView`s, so
    /// only the pixels say how wide the row's ink runs. Rasterise it over a backdrop far wider than
    /// the sidebar and find the rightmost painted column.
    /// A plain shell has nothing to report — no context, no counts — so it draws no row: its mark
    /// alone on a line read as a stray glyph under the System heading.
    @Test func aShellWithNothingToReportDrawsNoRow() {
        let none = host([], task: nil).fittingSize.height
        let shell = host([], task: UsageTaskRow(agent: .shell, context: nil)).fittingSize.height
        #expect(shell == none)
    }

    private func paintedWidth(_ rows: [UsageVendorRow], width: CGFloat, scale: InterfaceScale = .standard) throws -> CGFloat {
        // Two 1 pt rules run the footer's full width: the top one, and the one between SYSTEM and
        // USAGE. The band below the second holds the USAGE heading, which is narrower than any row,
        // and the rows.
        let host = host(rows, width: width, scale: scale)
        let system = scale(Space.tight) + scale(Size.menuRow) * 2 + scale(Space.base)
        return try paintedWidth(host, band: Int((system + 2).rounded(.up))..<Int(host.bounds.height.rounded(.up)))
    }

    /// `band` is in points from the top; it has to leave out every full-width rule.
    private func paintedWidth(_ host: NSHostingView<AnyView>, band points: Range<Int>) throws -> CGFloat {
        let bitmap = try #require(Snapshot.bitmap(of: host))
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        let band = Int(CGFloat(points.lowerBound) * scale)..<min(bitmap.pixelsHigh, Int(CGFloat(points.upperBound) * scale))
        // Sampled inside the band, past the rows' ink: the footer's middle can land on a rule.
        let backdrop = try #require(bitmap.colorAt(x: bitmap.pixelsWide - 2, y: (band.lowerBound + band.upperBound) / 2))
        for x in stride(from: bitmap.pixelsWide - 1, through: 0, by: -1) {
            for y in band where bitmap.colorAt(x: x, y: y).map({
                abs($0.redComponent - backdrop.redComponent) > 0.02
                    || abs($0.greenComponent - backdrop.greenComponent) > 0.02
                    || abs($0.blueComponent - backdrop.blueComponent) > 0.02
            }) == true {
                return CGFloat(x) / scale
            }
        }
        return 0
    }

    /// The first group is SYSTEM (spec 2026-10-05): with the Mac's row beside it, the heading no
    /// longer says what the context number is, so its row carries `ctx` (measured in
    /// `theTaskRowDrawsOnlyItsMarkAndContext`).
    @Test func theFirstGroupIsSystem() {
        #expect(SidebarFooter.systemHeading == "System")
    }

    /// SYSTEM is always there: with nothing selected it still holds the Mac's readings, one
    /// `Size.menuRow` line in the group's padding, then the rule and USAGE. At the desk that is all
    /// the Mac draws (proposal 3A).
    @Test func withNothingSelectedSystemHoldsTheMacsReadings() {
        let rows = [UsageVendorRow(vendor: .claude, lines: [week, fiveHour], note: nil)]
        let usage = Space.tight + Size.menuRow * 2 + Space.base
        let system = Space.tight + Size.menuRow * 2 + Space.base
        #expect(abs(host(rows).fittingSize.height - (system + 1 + usage)) < 0.5)
    }

    /// In the backpack, and while it switches, the mode's line adds one row under the readings.
    @Test(arguments: [MacMode.turningOn, .on, .needsYou(.lostHotspot), .turningOff])
    func theBackpackLineAddsOneRow(mode: MacMode) {
        let usage = Space.tight + Size.menuRow + Space.base
        let system = Space.tight + Size.menuRow * 3 + Space.base
        #expect(abs(host([], mode: mode).fittingSize.height - (system + 1 + usage)) < 0.5)
    }

    /// The readings row at its widest — three readings, each at 100 % — paints inside the sidebar's
    /// minimum at every interface size rather than truncating (proposal 1A's width budget).
    @Test(arguments: InterfaceScale.all)
    func theMacsReadingsFitTheMinimumSidebarWidth(scale: InterfaceScale) throws {
        let machine = [UsageLine(window: .cpu, percent: 100, warning: true), UsageLine(window: .ram, percent: 100, warning: true),
                       UsageLine(window: .battery, percent: 100, warning: false)]
        // Under SYSTEM's heading, the readings row alone.
        let top = Int((scale(Space.tight) + scale(Size.menuRow)).rounded(.up))
        let band = top..<(top + Int(scale(Size.menuRow)))
        let natural = try paintedWidth(host([], machine: machine, width: 900, scale: scale), band: band)
        let minimum = scale(Size.sidebarMinWidth)
        let atMinimum = try paintedWidth(host([], machine: machine, width: minimum, scale: scale), band: band)
        #expect(natural > scale(Size.vendorMark) * 4, "the row painted its readings, not its mark alone")
        #expect(abs(atMinimum - natural) < 1,
                "at ×\(scale.factor) the readings paint \(natural) pt unconstrained but only \(atMinimum) pt at the \(minimum) pt minimum")
    }
}
