import ShellforgeCore
import ShellforgeDesign
import SwiftUI

/// One of a project's tunnels, under its header and before its tasks: a dot for its state, its
/// alias and local ports, and the button that starts or stops it; under them, why it failed, or
/// that the config no longer has the host.
struct TunnelRowView: View {
    let row: TunnelRowItem
    let start: () -> Void
    let stop: () -> Void
    @Environment(\.interfaceScale) private var scale
    @Environment(\.surface) private var surface

    enum Action: Equatable { case start, stop }

    /// What the row shows for its state, as a value the tests read.
    struct Look: Equatable {
        let tone: TunnelState
        /// The button's; nil when the tunnel cannot start.
        let action: Action?
        let caption: String?
    }

    static func look(_ row: TunnelRowItem) -> Look {
        if row.missing { return Look(tone: .stopped, action: nil, caption: "Not in ~/.ssh/config") }
        switch row.state {
        case .stopped: return Look(tone: .stopped, action: .start, caption: nil)
        case .connecting, .up: return Look(tone: row.state, action: .stop, caption: nil)
        case .failed: return Look(tone: .failed, action: .start, caption: row.error)
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: scale(Space.tight)) {
            HStack(spacing: scale(Space.inset)) {
                ToneDot(color: Self.color(look.tone), size: scale(Size.statusMarkSmall))
                    .frame(width: scale(Size.avatar))
                RowTitle(row.alias, dimmed: row.missing)
                if !row.ports.isEmpty {
                    Text(row.ports).font(Typography.monoCode).foregroundStyle(surface.secondaryInk).lineLimit(1)
                }
                Spacer(minLength: scale(Space.tight))
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
            if let caption = look.caption {
                RowCaption(caption, warns: true).lineLimit(2).padding(.leading, scale(Size.avatar) + scale(Space.inset))
            }
        }
        .frame(minHeight: scale(Size.menuRow))
        .padding(.leading, scale(Space.base)).padding(.trailing, SidebarRowLayout.trailingInset(scale))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tunnel \(row.alias)")
        .accessibilityValue(row.missing ? "Not in SSH config" : row.state.rawValue)
    }
}
