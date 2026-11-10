import ShellforgeDesign
import SwiftUI

/// The header's place while the sidebar is rearranged, built like the header itself: the section
/// heading reads “Rearranging”, Cancel is a quiet text button, and only Done carries the accent, as
/// a small chip. With the window's buttons inside the sidebar it is pinned below their band. No
/// key equivalents: the terminal shares the window, so Return and Esc typed there must stay the
/// shell's. Esc cancels only from inside the sidebar (`SidebarHostingView.cancelOperation`).
struct RearrangeBar: View {
    let cancel: () -> Void
    let done: () -> Void
    /// Set while the window's buttons sit inside the sidebar: the bar is pinned below their band.
    var windowControls: SidebarWindowControls? = nil
    @Environment(\.interfaceScale) private var scale
    @Environment(\.surface) private var surface

    static let title = "Rearranging"
    static let cancelTitle = "Cancel"
    static let doneTitle = "Done"
    /// The bar's `ViewMark`.
    static let markName = "RearrangeBar"

    var body: some View {
        HStack(spacing: scale(Space.base)) {
            SidebarHeading(Self.title).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: scale(Space.tight))
            Button(Self.cancelTitle, action: cancel)
                .buttonStyle(.plain)
                .font(Typography.label)
                .foregroundStyle(surface.secondaryInk)
            Button(Self.doneTitle, action: done).buttonStyle(DoneChipStyle(scale: scale))
        }
        .frame(height: scale(Size.menuRow))
        .modifier(HeaderPlacement(windowControls: windowControls, scale: scale))
        .background(ViewMark(name: Self.markName))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.title)
    }
}

/// Done: the bar's one coloured control, a small accent capsule.
private struct DoneChipStyle: ButtonStyle {
    let scale: InterfaceScale

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.label)
            .foregroundStyle(Palette.onAccent)
            .padding(.horizontal, scale(Space.base))
            .padding(.vertical, scale(Space.hairline))
            .background(Capsule(style: .continuous).fill(Palette.accent))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
    }
}
