import ShellforgeCore
import ShellforgeDesign
import SwiftUI

/// The one line pinned under every panel: the Mac's CPU and memory, then each shown vendor's first
/// window (`wk` when it reports one) as a ring and a number beside the vendor's mark —
/// `cpu ◔ 23%  ram ◔ 61%  Ⓒ ◔ 84%  Ⓧ ◔ 12%`. It never wraps: vendors that would not fit fold into
/// “+N”. The whole strip is one control, and a click shows the Metrics panel, where the full footer is.
struct MetricsStrip: View {
    /// The Mac's readings (`MachineMonitor.lines`); the strip draws CPU and memory.
    let machine: [UsageLine]
    let vendors: [UsageVendorRow]
    /// Shows the Metrics panel (`opener`).
    let open: () -> Void
    @Environment(\.interfaceScale) private var scale

    /// The strip's `ViewMark`.
    static let markName = "MetricsStrip"
    static let helpText = "Show Metrics"

    /// Its height: a menu row on its card, `Space.tight` above and below inside it, and the footer's
    /// own `Space.base` under the card.
    static func height(_ scale: InterfaceScale) -> CGFloat {
        scale(Size.menuRow) + 2 * scale(Space.tight) + scale(Space.base)
    }

    /// The leading `fitting` vendors and how many fold into “+N” after them.
    static func visible(_ vendors: [UsageVendorRow], fitting: Int) -> (shown: [UsageVendorRow], hidden: Int) {
        let shown = Array(vendors.prefix(max(0, fitting)))
        return (shown, vendors.count - shown.count)
    }

    /// The Mac's readings the strip draws: CPU and memory; the battery waits for the Metrics panel.
    static func machineGauges(_ machine: [UsageLine]) -> [UsageLine] {
        machine.filter { $0.window == .cpu || $0.window == .ram }
    }

    /// A vendor's gauge: its first window, `wk` before `5h` as `UsageRows` orders them; nil for a note.
    static func gauge(_ row: UsageVendorRow) -> UsageLine? { row.lines.first }

    /// What a click on the strip does in `activity`'s window.
    static func opener(_ activity: ActivityModel) -> () -> Void {
        { [weak activity] in activity?.select(.metrics) }
    }

    var body: some View {
        let gauges = Self.machineGauges(machine)
        HStack(spacing: 0) {
            // The widest line that fits: every vendor, then one fewer behind a “+N”, down to none.
            ViewThatFits(in: .horizontal) {
                ForEach(Array((0...vendors.count).reversed()), id: \.self) { fitting in
                    line(gauges, Self.visible(vendors, fitting: fitting))
                }
            }
            Spacer(minLength: 0)
        }
        .font(Typography.mono)
        .monospacedDigit()
        .lineLimit(1)
        .frame(height: scale(Size.menuRow))
        .padding(.horizontal, SidebarRowLayout.listInset + scale(Space.base))
        .padding(.vertical, scale(Space.tight))
        .background {
            RoundedRectangle(cornerRadius: scale(Radius.group), style: .continuous)
                .fill(Palette.footerCard)
                .padding(.horizontal, SidebarRowLayout.listInset)
        }
        .padding(.bottom, scale(Space.base))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .help(Self.helpText)
        .background(ViewMark(name: Self.markName))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.label(machine: gauges, vendors: vendors))
        .accessibilityHint(Self.helpText)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, open)
    }

    /// The strip read as words: each reading's own, then each vendor's first window or its note.
    static func label(machine: [UsageLine], vendors: [UsageVendorRow]) -> String {
        (machine.map(\.help) + vendors.map { row in gauge(row)?.help ?? row.note ?? "" }).filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private func line(_ gauges: [UsageLine], _ folded: (shown: [UsageVendorRow], hidden: Int)) -> some View {
        HStack(spacing: scale(Space.inset)) {
            ForEach(gauges, id: \.window) { reading in
                HStack(spacing: 0) {
                    Text(reading.window.shortLabel + " ").foregroundStyle(Palette.muted)
                    ring(reading)
                }
                .help(reading.help)
            }
            ForEach(folded.shown, id: \.vendor) { row in
                HStack(spacing: scale(Space.tight)) {
                    VendorMark(agent: row.vendor, size: scale(Size.vendorMark))
                    if let window = Self.gauge(row) {
                        ring(window)
                    } else {
                        // A vendor waiting for data, or whose feed is broken: its note is in the panel.
                        Text("–").foregroundStyle(SidebarFooter.noteInk(row))
                    }
                }
                .help(Self.gauge(row)?.help ?? row.note ?? "")
            }
            if folded.hidden > 0 { Text("+\(folded.hidden)").foregroundStyle(Palette.muted) }
        }
        .fixedSize()
    }

    /// A reading's ring and number, amber past its warning, as the footer draws them.
    private func ring(_ line: UsageLine) -> some View {
        HStack(spacing: 0) {
            UsageRing(percent: line.percent, warning: line.warning, size: scale(Size.statusMark))
            Text(" \(line.percent)%").foregroundStyle(line.warning ? Palette.amber : Palette.text)
        }
    }
}

/// The strip as the sidebar draws it: the vendor rows recomputed on the minute, like the footer's.
struct MetricsStripHost: View {
    @ObservedObject var model: SidebarModel
    @ObservedObject var hooks: AgentHooksModel
    @ObservedObject var machine: MachineMonitor
    let open: () -> Void
    @Environment(\.footerClock) private var footerClock

    var body: some View {
        TimelineView(.everyMinute) { context in
            MetricsStrip(machine: machine.lines, vendors: model.vendorRows(at: context.date, clock: footerClock, hooks: hooks), open: open)
        }
    }
}
