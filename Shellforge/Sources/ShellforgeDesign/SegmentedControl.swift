// Ported from AiTerm (app/Sources/AiTermUI/SegmentedControl.swift), GPLv3, Laurens D'Hondt.
import SwiftUI

/// The segmented track the agent picker and the Settings tab bar are both drawn from.
///
/// 28 pt overall — `Size.control`, so it lines up with the fields beside it — which is a 24 pt
/// segment inside a 2 pt track, and a 6 pt segment radius concentric inside the track's 8. This
/// existed twice before, at 30 pt and at 34 pt, because neither copy knew about the other.
///
/// It is hand-built rather than a `Picker`: the system segmented control cannot carry a logo and
/// paints its selection in the accent colour.
///
/// It inks each segment for its ground — the selected one in the surface's ink, white on the
/// accent; the rest in its secondary ink — so a segment's label is plain `Text` that sets no colour.
public struct SegmentedControl<Value: Hashable, Content: View>: View {
    /// How the selected segment is marked.
    public enum Style: Equatable, Sendable {
        /// A neutral fill (`controlActive`) under the selected segment, and the house focus ring
        /// around the track while it has the keyboard: the agent picker, the sidebar size.
        case neutral
        /// The accent under the selected segment, which is then drawn on `.surface(.accent)`, and no
        /// focus ring: the track still takes the keyboard and answers ← and →, but a ring in the
        /// accent around an accent segment reads as a second selection. The Settings tab bar.
        case accent
    }

    let values: [Value]
    @Binding var selection: Value
    let style: Style
    let isSelectable: (Value) -> Bool
    let help: (Value) -> String?
    @ViewBuilder var content: (Value, Bool) -> Content
    // `@FocusState` is a normal property wrapper, not a macro, so it compiles without Xcode.
    @FocusState private var focused: Bool

    /// `isSelectable` says which segments can be picked; the rest stay in place, dimmed and
    /// disabled. `help` is a segment's tooltip, or `nil` for none.
    public init(values: [Value], selection: Binding<Value>, style: Style = .neutral,
                isSelectable: @escaping (Value) -> Bool = { _ in true },
                help: @escaping (Value) -> String? = { _ in nil },
                @ViewBuilder content: @escaping (Value, Bool) -> Content) {
        self.values = values
        self._selection = selection
        self.style = style
        self.isSelectable = isSelectable
        self.help = help
        self.content = content
    }

    public var body: some View {
        HStack(spacing: Space.hairline) {
            ForEach(values, id: \.self) { value in
                let on = value == selection, selectable = isSelectable(value)
                Button { selection = value } label: {
                    SegmentInk(on: on) { content(value, on) }
                        .frame(maxWidth: .infinity)
                        .frame(height: Size.control - 2 * Space.hairline)
                        .background(RoundedRectangle(cornerRadius: Radius.control).fill(on ? selectedFill : .clear))
                        .contentShape(Rectangle())
                }
                .segmentButtonStyle(selectable: selectable)
                .opacity(selectable ? 1 : 0.4)
                .transformEnvironment(\.surface) { if on && style == .accent { $0 = .accent } }
                .optionalHelp(help(value))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(Space.hairline)
        .groupChrome()
        // A segmented control answers to ← and → on macOS. Without this the track could be reached
        // by tab and then did nothing, which is worse than not being focusable at all.
        .focusable()
        .focused($focused)
        // SwiftUI otherwise adds its own compositor-drawn halo as well as the house focus ring.
        .modifier(FocusEffectOff())
        .focusRing(style == .neutral && focused, cornerRadius: Radius.group)
        .onMoveCommand { direction in
            switch direction {
            case .left: step(-1)
            case .right: step(1)
            default: break
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var selectedFill: Color { style == .accent ? Palette.tabActive : Palette.controlActive }

    /// Moves the selection by `delta`, skipping anything that cannot be picked and stopping at the
    /// ends.
    private func step(_ delta: Int) {
        guard var index = values.firstIndex(of: selection) else { return }
        repeat {
            index += delta
            guard values.indices.contains(index) else { return }
        } while !isSelectable(values[index])
        selection = values[index]
    }
}

/// A segment's label in the ink of the ground it is drawn on, which the control has already
/// declared: `.accent` under an accent-style selection, else the ground the track sits on.
private struct SegmentInk<Label: View>: View {
    let on: Bool
    @ViewBuilder let label: () -> Label
    @Environment(\.surface) private var surface

    var body: some View {
        label().foregroundStyle(on ? surface.ink : surface.secondaryInk)
    }
}

private extension View {
    /// A segment that cannot be picked is disabled, so VoiceOver reads it as dimmed and a click does
    /// nothing. It is drawn bare rather than `.plain`, whose own disabled look would dim it again on
    /// top of the track's 40 %; at rest the two draw the same pixels.
    @ViewBuilder
    func segmentButtonStyle(selectable: Bool) -> some View {
        if selectable {
            buttonStyle(.plain)
        } else {
            buttonStyle(UnselectableSegmentStyle()).disabled(true)
        }
    }

    @ViewBuilder
    func optionalHelp(_ text: String?) -> some View {
        if let text { help(text) } else { self }
    }
}

private struct UnselectableSegmentStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

/// `.focusEffectDisabled()` where it exists: macOS 14 and later. On 13 SwiftUI draws no halo of its
/// own around a focusable view, so there is nothing to turn off.
private struct FocusEffectOff: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14, *) { content.focusEffectDisabled() } else { content }
    }
}
