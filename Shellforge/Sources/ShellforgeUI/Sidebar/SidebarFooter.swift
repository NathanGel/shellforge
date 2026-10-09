// Ported from AiTerm (app/Sources/AiTerm/Views/SidebarFooter.swift), GPLv3, Laurens D'Hondt.
import SwiftUI
import ShellforgeCore
import ShellforgeDesign

/// The sidebar's foot, on the list's grid: SYSTEM, then USAGE, split by a rule. SYSTEM is the
/// selected task's or terminal's context — its active tab's mark, `ctx`, the ring and the fill, then
/// what that tab's conversation has spent, `in 936k · out 5.6k` (proposal A, 8 Oct 2026) — then
/// the Mac (proposal 1A · 2A · 3A, 6 Oct 2026): its readings, `cpu ◔ 23% · ram ◔ 61%` and `bat` on
/// battery, under its `macbook` mark, and while Backpack Mode is on or switching, a line in a
/// `SettingsTone` — `● backpack enabled`. At the desk there is no such line: the readings row is the
/// Mac's row, and its click is ⌘B. USAGE is one row per vendor with its account windows:
/// `Ⓒ wk ◔ 84% Mon 21:00 · 5h ◔ 23% 16:40`. With nothing selected SYSTEM holds the Mac alone.
///
/// It sits on the list's grid rather than its own (proposal A, 23 Sep 2026): the headings are the
/// `PROJECTS` header's treatment, the rows are ``Size/menuRow`` like the header and `DividerRow`,
/// and the ink runs from the header's leading edge to the status column's — the list's inset plus
/// `Space.base` on both sides. Each group has the footer's own padding, `Space.tight` above and
/// `Space.base` below, so the rule between them reads like the scroll-edge hairline above both.
///
/// Every window shows when it clears, so the row answers "how much is left, and until when?"
/// without being hovered. `ctx` and the Mac's readings are the exception and carry no clock: a
/// conversation's context is emptied by compaction, not by a reset time, and the Mac's are now.
/// Paying for the clock times in width rather than in a wider fill keeps the numbers glanceable;
/// ``Size/sidebarMinWidth`` is sized to the resulting common case.
///
/// Every ring and number is drawn in one of two inks, `Palette.text` or `Palette.amber` past the
/// warning threshold — for the Mac's readings, when macOS itself warns — whatever the agent is
/// doing: an idle vendor's last reading is still its reading, and a dimmed ring beside a bright one
/// reads as a different kind of mark. The backpack line is the one other colour. The counts have no
/// ring and are never amber: a count has no ceiling to fill towards, and spending is not a warning.
struct SidebarFooter: View {
    let task: UsageTaskRow?
    let rows: [UsageVendorRow]
    /// The Mac's readings, in their order (`MachineMonitor`). Empty, the row draws its mark alone.
    var machine: [UsageLine] = []
    /// The Mac's mode, as one drawn line (spec 2026-10-05). The defaults draw a Mac at its desk.
    var mac: MacModeLine = MacModePresentation.line(mode: .desk, hotspot: nil, wifi: nil)
    /// A click on the Mac's rows.
    var toggleMac: () -> Void = {}
    /// A right-click on them opens Mac Settings.
    var openMacSettings: () -> Void = {}
    @Environment(\.interfaceScale) private var scale

    /// The first group's heading. It holds more than the context, so the context row names its
    /// gauge with `ctx`.
    static let systemHeading = "System"
    /// The Mac's mark on its readings row, as the Mac card draws it.
    static let macSymbol = "macbook"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            group(Self.systemHeading) {
                if let task {
                    telemetryRow(mark: vendorMark(task.agent)) {
                        if task.context != nil || task.tokens != nil {
                            // One zero-spacing run, as a vendor row's windows are: the row's own
                            // spacing would open a gap between `ctx` and the counts.
                            HStack(spacing: 0) {
                                if let context = task.context { usageWindows([context]) }
                                if let tokens = task.tokens { tokenCounts(tokens, afterContext: task.context != nil) }
                            }
                        } else if task.agent != .shell {
                            // A shell has no context to wait for; an agent has not reported yet.
                            Text("No context yet").foregroundStyle(Palette.muted)
                        }
                    }
                }
                macReadings
                backpackLine
            }
            Hairline()
            group("Usage") {
                ForEach(rows, id: \.vendor) { row in
                    telemetryRow(mark: vendorMark(row.vendor)) {
                        if let note = row.note {
                            Text(note).foregroundStyle(Self.noteInk(row))
                        } else {
                            usageWindows(row.lines)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Hairline() }
    }

    /// The Mac's readings under its mark, read out as one element: its readings in words, then the
    /// mode. Before the first sample it is still the Mac's button, so it says "Mac".
    private var macReadings: some View {
        macControl(
            telemetryRow(mark: SymbolMark(symbol: Self.macSymbol, size: scale(Size.vendorMark), style: .paper)) {
                usageWindows(machine)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.readingsLabel(machine))
            .accessibilityHint(mac.help)
        )
    }

    /// The readings row's VoiceOver label: each reading's words, or "Mac" while there are none.
    static func readingsLabel(_ machine: [UsageLine]) -> String {
        machine.isEmpty ? "Mac" : machine.map(\.help).joined(separator: ", ")
    }

    /// While Backpack Mode is on or switching: its `ToneDot` centred in the marks' column, then its
    /// words in the same tone. Nothing at the desk.
    @ViewBuilder private var backpackLine: some View {
        if let tone = mac.mode.tone, let words = mac.mode.words {
            macControl(
                telemetryRow(mark: ToneDot(tone: tone, size: scale(Size.statusMarkSmall)).frame(width: scale(Size.vendorMark))) {
                    Text(words).foregroundStyle(tone.color)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(mac.help)
            )
        }
    }

    /// What makes a row the Mac's: a click is ⌘B, a right-click offers Mac Settings…, and the mode's
    /// sentence is its tooltip wherever a reading's own does not cover it.
    private func macControl(_ row: some View) -> some View {
        row
            .contentShape(Rectangle())
            .onTapGesture(perform: toggleMac)
            .contextMenu { Button("Mac Settings…", action: openMacSettings) }
            .help(mac.help)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, toggleMac)
    }

    /// Amber, like the iTerm2 banner's warning, for a feed that is broken; a quiet one's note recedes.
    static func noteInk(_ row: UsageVendorRow) -> Color { row.warning ? Palette.amber : Palette.muted }

    /// The footer sits below the `List`, not in it, so it adds the list's own inset — the
    /// `Space.inset` the snapshot harness stands in for it with — to the rows' `Space.base`.
    private var edge: CGFloat { scale(Space.inset) + scale(Space.base) }

    /// A heading in the `PROJECTS` header's treatment, then its rows, in the footer's own padding.
    private func group(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarHeading(title)
                .frame(height: scale(Size.menuRow))
            rows()
        }
        .padding(.horizontal, edge)
        .padding(.top, scale(Space.tight))
        .padding(.bottom, scale(Space.base))
    }

    private func vendorMark(_ agent: SessionAgent) -> VendorMark { VendorMark(agent: agent, size: scale(Size.vendorMark)) }

    /// One footer line: a mark in the ``Size/vendorMark`` column, then its readings in the
    /// telemetry's mono face.
    private func telemetryRow(mark: some View, @ViewBuilder readings: () -> some View) -> some View {
        HStack(alignment: .center, spacing: scale(Space.inset)) {
            mark
            readings()
            Spacer(minLength: 0)
        }
        .font(Typography.mono)
        .monospacedDigit()
        .lineLimit(1)
        .frame(height: scale(Size.menuRow), alignment: .leading)
    }

    /// A zero-spacing stack keeps punctuation and colour changes from adding invisible layout
    /// gaps; each segment's own spaces live inside its `Text`, so the ring sits in the gap the
    /// four-cell bar used to occupy. `usageVendorRows` supplies wk before 5h; this renderer
    /// preserves that order. Every window names itself, the context row's `ctx` included.
    private func usageWindows(_ lines: [UsageLine]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                if index > 0 { Text(" · ").foregroundStyle(Palette.muted).accessibilityHidden(true) }
                // One element per window — label, ring, number and reset — read and hovered as its
                // words: the glyphs alone say "wk", a ring and "Sat".
                HStack(spacing: 0) {
                    Text(line.window.shortLabel + " ").foregroundStyle(Palette.muted)
                    UsageRing(percent: line.percent, warning: line.warning, size: scale(Size.statusMark))
                    Text(" \(line.percent)%")
                        .foregroundStyle(line.warning ? Palette.amber : Palette.text)
                    // The percentage is the number being watched; the reset recedes behind it.
                    if let reset = line.reset { Text(" " + reset).foregroundStyle(Palette.muted) }
                }
                .contentShape(Rectangle())
                .help(line.help)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(line.help)
            }
        }
    }

    /// The active tab's spend after its `ctx`: `in 936k · out 5.6k`, the labels muted and the numbers
    /// in the text ink, like a window's — but with no ring, a count having no ceiling to fill towards,
    /// and never amber. Hovered and read as one sentence (`TokenTally.help`): the glyphs alone say
    /// "in", "out" and two numbers.
    private func tokenCounts(_ tokens: TokenTally, afterContext: Bool) -> some View {
        HStack(spacing: 0) {
            if afterContext { Text(" · ").foregroundStyle(Palette.muted).accessibilityHidden(true) }
            HStack(spacing: 0) {
                Text(TokenTally.inputLabel + " ").foregroundStyle(Palette.muted)
                Text(TokenTally.short(tokens.input)).foregroundStyle(Palette.text)
                Text(" · ").foregroundStyle(Palette.muted)
                Text(TokenTally.outputLabel + " ").foregroundStyle(Palette.muted)
                Text(TokenTally.short(tokens.output)).foregroundStyle(Palette.text)
            }
            .contentShape(Rectangle())
            .help(tokens.help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tokens.help)
        }
    }
}

/// The fill beside a telemetry number: a ring that closes clockwise as the window fills.
///
/// Deliberately not a primitive — the reuse ladder in `AiTermUI/README.md` promotes a pattern only
/// once a second file needs it, and this is the footer's alone. It is drawn to `StatusMark`'s
/// recipe (same diameter, same `size * 0.15` stroke, same round cap) so the two round marks in the
/// sidebar read as one family rather than as two people's circles.
struct UsageRing: View {
    let percent: Int
    let warning: Bool
    /// The ring's diameter in points; the caller scales ``Size/statusMark``.
    let size: CGFloat

    /// How much of the circle to close. Clamped, because the percentage is another process's
    /// arithmetic and `trim(from:to:)` past 1 wraps back over the ring's own start.
    static func fill(_ percent: Int) -> CGFloat { min(1, max(0, CGFloat(percent) / 100)) }

    var body: some View {
        ZStack {
            Circle().strokeBorder(Palette.spinnerTrack, lineWidth: size * 0.15)
            Circle()
                .trim(from: 0, to: Self.fill(percent))
                .stroke(warning ? Palette.amber : Palette.text,
                        style: StrokeStyle(lineWidth: size * 0.15, lineCap: .round))
                // `trim` starts at three o'clock; a fill reads as rising from the top.
                .rotationEffect(.degrees(-90))
                // `strokeBorder` insets by half its width, `stroke` straddles the path — inset the
                // fill to match, or it paints a hair outside the track it is supposed to fill.
                .padding(size * 0.15 / 2)
        }
        .frame(width: size, height: size)
    }
}
