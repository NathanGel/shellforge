import ShellforgeCore
import ShellforgeDesign
import SwiftUI

/// One of a project's tunnels, under its header and before its tasks: a dot for its state, its
/// alias and local ports, whether it keeps running past a quit, and the button that starts or stops
/// it; under them, how long it has been up and its traffic, that a tab holds it, why it failed —
/// with Answer in Tab when ssh needed an answer — or that the config no longer has the host.
struct TunnelRowView: View {
    let row: TunnelRowItem
    let start: () -> Void
    let stop: () -> Void
    var answerInTab: () -> Void = {}
    /// Rearrange mode, greyed while another window is in it: the row's one menu item.
    var canRearrange = true
    var rearrange: () -> Void = {}
    /// False where the row cannot be rearranged at all (the SSH panel): no menu, no Rearrange action.
    var offersRearrange = true
    @Environment(\.interfaceScale) private var scale
    @Environment(\.surface) private var surface

    enum Action: Equatable { case start, stop }

    /// What the row shows for its state, as a value the tests read.
    struct Look: Equatable {
        let tone: TunnelState
        /// The button's; nil when the tunnel cannot start, or a tab holds it.
        let action: Action?
        let caption: String?
        /// ssh needed an answer: the row offers to run it in a tab.
        var answersInTab = false
    }

    static func look(_ row: TunnelRowItem) -> Look {
        if row.missing { return Look(tone: .stopped, action: nil, caption: "Not in ~/.ssh/config") }
        // Stopping a tunnel a tab holds is closing that tab's ssh, which is the user's to do.
        if row.heldBy != nil { return Look(tone: row.state, action: nil, caption: nil) }
        switch row.state {
        case .stopped: return Look(tone: .stopped, action: .start, caption: nil)
        case .connecting, .up: return Look(tone: row.state, action: .stop, caption: nil)
        case .failed: return Look(tone: .failed, action: .start, caption: row.error, answersInTab: row.needsInput == true)
        }
    }

    /// How long a tunnel has been up: `0m`, `59m`, `2h 5m`, `3d 4h`.
    static func uptime(seconds: Double) -> String {
        let minutes = max(0, Int(seconds) / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }

    /// The line under an up tunnel: its uptime, then its traffic once sampled; "In a tab" while a
    /// tab holds it. Nothing for any other state.
    static func detail(_ row: TunnelRowItem, now: Date) -> String? {
        if row.heldBy == .tab { return "In a tab" }
        guard row.state == .up, !row.missing else { return nil }
        var line = "up \(uptime(seconds: now.timeIntervalSince1970 - row.since))"
        if let received = row.bytesIn, let sent = row.bytesOut {
            line += " · ↓ \(bytes(received)) ↑ \(bytes(sent))"
        }
        return line
    }

    private static func bytes(_ count: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file) }

    /// The ports' tooltip: which tunnel holds them, so ssh's warning in a tab is not read as a failure.
    static func portsHelp(_ row: TunnelRowItem) -> String? {
        // Only while something holds them: a stopped tunnel holds no port.
        guard !row.missing, [.connecting, .up].contains(row.state) else { return nil }
        return "Held by \(row.alias): ssh \(row.alias) in a tab warns it cannot bind \(row.ports), and still connects."
    }

    /// Stopped is quiet, connecting amber, up green, failed red.
    static func color(_ state: TunnelState) -> Color {
        switch state {
        case .stopped: Palette.muted
        case .connecting: Palette.amber
        case .up: Palette.green
        case .failed: Palette.destructive
        }
    }

    private var look: Look { Self.look(row) }

    /// Answer in Tab's glyph, in Sessions and the SSH panel alike.
    static let answerInTabSymbol = "keyboard"
    /// What VoiceOver says for the keep-running pin.
    static let keepsRunningText = "Keeps running after quit"

    var body: some View {
        TunnelRowContent(alias: row.alias, row: row, dimmed: row.missing, caption: look.caption) {
            if look.answersInTab {
                Button(action: answerInTab) {
                    Image(systemName: Self.answerInTabSymbol).font(Typography.micro).foregroundStyle(surface.secondaryInk)
                }
                .buttonStyle(.plain)
                .frame(width: SidebarRowLayout.trailingSlot(scale), height: SidebarRowLayout.trailingSlot(scale))
                .help("Answer in Tab: ssh needs an answer")
                .accessibilityLabel("Answer \(row.alias) in a tab")
            }
            if let action = look.action {
                Button(action: action == .start ? start : stop) {
                    Image(systemName: action == .start ? "play.fill" : "stop.fill")
                        .font(Typography.micro).foregroundStyle(surface.secondaryInk)
                }
                .buttonStyle(.plain)
                .frame(width: SidebarRowLayout.trailingSlot(scale), height: SidebarRowLayout.trailingSlot(scale))
                .help(action == .start ? "Start \(row.alias)" : "Stop \(row.alias)")
                .accessibilityLabel(action == .start ? "Start \(row.alias)" : "Stop \(row.alias)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tunnel \(row.alias)")
        .accessibilityValue(row.missing ? "Not in SSH config" : row.state.rawValue)
        .modifier(TunnelRowRearrange(offered: offersRearrange, enabled: canRearrange, action: rearrange))
    }

    /// The context menu's items.
    static let menuTitles = [RearrangeMenuItem.title]
}

/// A tunnel row's Rearrange, in its menu and to VoiceOver; nothing at all where it isn't offered,
/// rather than an item that is always grey.
private struct TunnelRowRearrange: ViewModifier {
    let offered: Bool
    let enabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if offered {
            content
                .modifier(RearrangeAccessibilityAction(canRearrange: enabled, action: action))
                .rowContextMenu { RearrangeMenuItem(enabled: enabled, action: action) }
        } else {
            content
        }
    }
}

/// What a tunnel's row and an SSH host's row both draw: a dot for the tunnel's state, the alias,
/// the tunnel's ports and keep-running pin, then `trailing`'s buttons; under them a caption and,
/// re-drawn each minute, the tunnel's uptime and traffic. A host that is no tunnel (`row` nil) has
/// no dot, its slot kept empty so the aliases line up. The caller adds its own accessibility.
struct TunnelRowContent<Trailing: View>: View {
    let alias: String
    let row: TunnelRowItem?
    let dimmed: Bool
    let caption: String?
    /// A tunnel's caption is a warning; a plain host's “not in the config” is not.
    var captionWarns = true
    @ViewBuilder let trailing: () -> Trailing
    @Environment(\.interfaceScale) private var scale
    @Environment(\.surface) private var surface

    private var captionInset: CGFloat { scale(Size.avatar) + scale(Space.inset) }

    var body: some View {
        VStack(alignment: .leading, spacing: scale(Space.tight)) {
            HStack(spacing: scale(Space.inset)) {
                if let row {
                    ToneDot(color: TunnelRowView.color(TunnelRowView.look(row).tone), size: scale(Size.statusMarkSmall))
                        .frame(width: scale(Size.avatar))
                } else {
                    Color.clear.frame(width: scale(Size.avatar), height: scale(Size.statusMarkSmall))
                }
                RowTitle(alias, dimmed: dimmed)
                if let row, !row.ports.isEmpty {
                    Text(row.ports).font(Typography.monoCode).foregroundStyle(surface.secondaryInk).lineLimit(1)
                        .help(TunnelRowView.portsHelp(row) ?? "")
                }
                if row?.keepRunning == true {
                    Image(systemName: "pin.fill").font(Typography.micro).foregroundStyle(surface.secondaryInk)
                        .help("Keeps running after Shellforge quits")
                        .accessibilityLabel(TunnelRowView.keepsRunningText)
                }
                Spacer(minLength: scale(Space.tight))
                trailing()
            }
            if let caption {
                RowCaption(caption, warns: captionWarns).lineLimit(captionWarns ? 2 : 1).padding(.leading, captionInset)
            }
            if let row {
                // Re-drawn each minute, for the uptime.
                TimelineView(.everyMinute) { context in
                    if let detail = TunnelRowView.detail(row, now: context.date) {
                        RowCaption(detail).lineLimit(1).padding(.leading, captionInset)
                    }
                }
            }
        }
        .frame(minHeight: scale(Size.menuRow))
        .padding(.leading, scale(Space.base)).padding(.trailing, SidebarRowLayout.trailingInset(scale))
    }
}
