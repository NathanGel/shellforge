import ShellforgeDesign
import SwiftUI

/// The header's place while the sidebar is rearranged: an accent-coloured bar, so the mode reads at
/// a glance, saying what is going on, with Cancel and Done. With the window's buttons inside the
/// sidebar it sits on their row, after them. No key equivalents: the terminal shares the window, so
/// Return and Esc typed there must stay the shell's. Esc cancels only from inside the sidebar
/// (`SidebarHostingView.cancelOperation`).
struct RearrangeBar: View {
    let cancel: () -> Void
    let done: () -> Void
    /// Set while the window's buttons sit inside the sidebar: the bar shares their row.
    var windowControls: SidebarWindowControls? = nil
    @Environment(\.interfaceScale) private var scale

    static let title = "Rearranging"
    static let cancelTitle = "Cancel"
    static let doneTitle = "Done"

    var body: some View {
        HStack(spacing: scale(Space.base)) {
            Text(Self.title).font(Typography.sectionHeader).foregroundStyle(Palette.onAccent)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: scale(Space.tight))
            Button(Self.cancelTitle, action: cancel).buttonStyle(BarButtonStyle(prominent: false, scale: scale))
            Button(Self.doneTitle, action: done).buttonStyle(BarButtonStyle(prominent: true, scale: scale))
        }
        .padding(.horizontal, scale(Space.base))
        .frame(height: scale(Size.menuRow))
        .background { RoundedRectangle(cornerRadius: scale(Radius.control), style: .continuous).fill(Palette.accent) }
        .modifier(HeaderPlacement(windowControls: windowControls, scale: scale))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.title)
    }
}

/// The bar's buttons, on the accent: Done filled in the bar's ink with accent text, Cancel a quiet
/// tint of it.
private struct BarButtonStyle: ButtonStyle {
    let prominent: Bool
    let scale: InterfaceScale

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.label)
            .foregroundStyle(prominent ? Palette.accent : Palette.onAccent)
            .padding(.horizontal, scale(Space.base))
            .padding(.vertical, scale(Space.tight))
            .background {
                RoundedRectangle(cornerRadius: scale(Radius.chip), style: .continuous)
                    .fill(prominent ? Palette.onAccent : Palette.keycapFill)
            }
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Rectangle())
    }
}
