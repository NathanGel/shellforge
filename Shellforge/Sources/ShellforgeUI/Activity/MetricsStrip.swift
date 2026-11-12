import ShellforgeCore
import ShellforgeDesign
import SwiftUI

/// The two lines pinned under every panel. The first is the Mac's CPU and memory; the second each
/// shown vendor's mark, then its `5h` and `wk` windows as a ring and a number —
/// `cpu ◔ 23%  ram ◔ 61%` over `Ⓒ 5h ◔ 42% · wk ◔ 84%  Ⓧ wk ◔ 12%`. Neither line wraps: vendors
/// that would not fit fold into “+N”. The whole strip is one control, and a click shows the Metrics
/// panel, where the full footer is — unless the Metrics panel is hidden, when the strip is only read.
struct MetricsStrip: View {
    /// The Mac's readings (`MachineMonitor.lines`); the strip draws CPU and memory.
    let machine: [UsageLine]
    let vendors: [UsageVendorRow]
    /// Shows the Metrics panel (`opener`); nil while it is hidden, when the strip is no control.
    let open: (() -> Void)?
    /// What a vendor is called when the strip is read out: `SidebarModel.agentName`.
    var agentName: @MainActor (SessionAgent) -> String = { $0.rawValue }
    @Environment(\.interfaceScale) private var scale

    /// The strip's `ViewMark`.
    static let markName = "MetricsStrip"
    static let helpText = "Show Metrics"

    /// Its height: two menu rows on its card, `Space.tight` above and below inside it, and the
    /// footer's own `Space.base` under the card.
    static func height(_ scale: InterfaceScale) -> CGFloat {
        2 * scale(Size.menuRow) + 2 * scale(Space.tight) + scale(Space.base)
    }

    /// The leading `fitting` vendors, each with its windows, and how many fold into “+N” after them.
    static func visible(_ vendors: [UsageVendorRow], fitting: Int) -> (shown: [UsageVendorRow], hidden: Int) {
        let shown = Array(vendors.prefix(max(0, fitting)))
        return (shown, vendors.count - shown.count)
    }

    /// The Mac's readings the strip draws: CPU and memory; the battery waits for the Metrics panel.
    static func machineGauges(_ machine: [UsageLine]) -> [UsageLine] {
        machine.filter { $0.window == .cpu || $0.window == .ram }
    }

    /// A vendor's gauges in ``UsageLine/Window/displayOrder``: a window it did not report is left out, and a vendor
    /// with only a note has none.
    static func windows(_ row: UsageVendorRow) -> [UsageLine] {
        row.linesInDisplayOrder
    }

    /// A window's number ink: amber past its own warning, the text ink below it.
    static func ink(_ line: UsageLine) -> Color { line.warning ? Palette.amber : Palette.text }

    /// What a click on the strip does in `activity`'s window: nothing, and no click, while the
    /// Metrics panel is hidden.
    static func opener(_ activity: ActivityModel) -> (() -> Void)? {
        guard !activity.layout.hidden.contains(.metrics) else { return nil }
        return { [weak activity] in activity?.select(.metrics) }
    }

    var body: some View {
        let gauges = Self.machineGauges(machine)
        VStack(alignment: .leading, spacing: 0) {
            lineFrame {
                HStack(spacing: scale(Space.inset)) {
                    ForEach(gauges, id: \.window) { reading in
                        labelled(reading).help(reading.help)
                    }
                }
                .fixedSize()
            }
            lineFrame {
                // The widest line that fits: every vendor, then one fewer behind a “+N”, down to none.
                ViewThatFits(in: .horizontal) {
                    ForEach(Array((0...vendors.count).reversed()), id: \.self) { fitting in
                        usage(Self.visible(vendors, fitting: fitting))
                    }
                }
            }
        }
        .font(Typography.monoCode)
        .monospacedDigit()
        .lineLimit(1)
        .padding(.horizontal, SidebarRowLayout.listInset + scale(Space.base))
        .padding(.vertical, scale(Space.tight))
        .background {
            RoundedRectangle(cornerRadius: scale(Radius.group), style: .continuous)
                .fill(Palette.footerCard)
                .padding(.horizontal, SidebarRowLayout.listInset)
        }
        .padding(.bottom, scale(Space.base))
        .background(ViewMark(name: Self.markName))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.label(machine: gauges, vendors: vendors, name: agentName))
        .modifier(Opener(open: open))
    }

    /// The strip as a control that shows the Metrics panel, when there is one to show.
    private struct Opener: ViewModifier {
        let open: (() -> Void)?

        func body(content: Content) -> some View {
            if let open {
                content
                    .contentShape(Rectangle())
                    .onTapGesture(perform: open)
                    .help(MetricsStrip.helpText)
                    .accessibilityHint(MetricsStrip.helpText)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction(.default, open)
            } else {
                content
            }
        }
    }

    /// The strip read as words: each reading's own, then each vendor by name with its windows in
    /// ``UsageLine/Window/displayOrder`` — “Claude Code: 5-hour limit 42 % used, weekly limit 84 % used” — or its note.
    static func label(machine: [UsageLine], vendors: [UsageVendorRow], name: (SessionAgent) -> String) -> String {
        let readings = vendors.map { row in
            let lines = windows(row)
            let said = lines.isEmpty ? (row.note ?? "") : lines.map { "\($0.window.name.lowercased()) \($0.percent) % used" }.joined(separator: ", ")
            return said.isEmpty ? "" : "\(name(row.vendor)): \(said)"
        }
        return (machine.map(\.help) + readings).filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// One of the strip's lines: a menu row high, leading, its content never wrapped.
    private func lineFrame(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 0) {
            content()
            Spacer(minLength: 0)
        }
        .frame(height: scale(Size.menuRow))
    }

    /// Line 2: each shown vendor's mark and windows, then “+N” for those folded away.
    private func usage(_ folded: (shown: [UsageVendorRow], hidden: Int)) -> some View {
        HStack(spacing: scale(Space.inset)) {
            ForEach(folded.shown, id: \.vendor) { row in
                let lines = Self.windows(row)
                let vendor = HStack(spacing: scale(Space.tight)) {
                    VendorMark(agent: row.vendor, size: scale(Size.vendorMark))
                    if lines.isEmpty {
                        // A vendor waiting for data, or whose feed is broken: its note is the tooltip
                        // and in the panel, and the dash takes the note's ink — amber when broken.
                        Text("–").foregroundStyle(SidebarFooter.noteInk(row))
                    } else {
                        HStack(spacing: 0) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                if index > 0 { Text(" · ").foregroundStyle(Palette.muted) }
                                labelled(line).help(line.help)
                            }
                        }
                    }
                }
                // The note covers the mark and the dash alike; a vendor with windows has theirs.
                if lines.isEmpty, let note = row.note { vendor.help(note) } else { vendor }
            }
            if folded.hidden > 0 { Text("+\(folded.hidden)").foregroundStyle(Palette.muted) }
        }
        .fixedSize()
    }

    /// A reading's short label, ring and number, amber past its warning, as the footer draws them.
    private func labelled(_ line: UsageLine) -> some View {
        HStack(spacing: 0) {
            Text(line.window.shortLabel + " ").foregroundStyle(Palette.muted)
            UsageRing(percent: line.percent, warning: line.warning, size: scale(Size.stripGauge))
            Text(" \(line.percent)%").foregroundStyle(Self.ink(line))
        }
    }
}

/// The strip as the sidebar draws it: the vendor rows recomputed on the minute, like the footer's.
struct MetricsStripHost: View {
    @ObservedObject var model: SidebarModel
    @ObservedObject var hooks: AgentHooksModel
    @ObservedObject var machine: MachineMonitor
    let open: (() -> Void)?
    @Environment(\.footerClock) private var footerClock

    var body: some View {
        TimelineView(.everyMinute) { context in
            MetricsStrip(machine: machine.lines, vendors: model.vendorRows(at: context.date, clock: footerClock, hooks: hooks), open: open,
                         agentName: model.agentName)
        }
    }
}
