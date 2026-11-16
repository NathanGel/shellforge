import AppKit
import ShellforgeCore
import ShellforgeDesign
import SwiftUI

/// The top of the Sessions panel: a field that filters tasks by name, ticket, branch or project, and
/// chips for All, the ones waiting on you and the ones working. Esc in the field clears it.
struct SidebarFilterBar: View {
    @ObservedObject var model: SidebarModel
    @State private var focused = false
    @Environment(\.interfaceScale) private var scale

    static let placeholder = "Filter tasks"
    /// The states a chip is offered for, in order.
    static let chipStates: [SessionState] = [.needsInput, .working]

    static func chipHelp(_ state: SessionState) -> String {
        switch state {
        case .needsInput: "Show what needs you"
        case .working: "Show what’s working"
        case .idle: "Show what’s idle"
        case .done: "Show what’s done"
        }
    }

    private var text: Binding<String> {
        Binding(get: { model.rowFilter.text }, set: { model.rowFilter.text = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: scale(Space.snug)) {
            SearchField(placeholder: Self.placeholder, text: text, focused: $focused, onCommand: command)
                .fieldChrome(focused: focused)
            HStack(spacing: scale(Space.snug)) {
                FilterChip(selected: model.rowFilter.status == nil, help: "Show everything",
                           action: { model.rowFilter.status = nil }) {
                    Text("All \(model.childCount)")
                }
                ForEach(Self.chipStates, id: \.self) { state in
                    FilterChip(selected: model.rowFilter.status == state, help: Self.chipHelp(state),
                               action: { model.rowFilter.status = model.rowFilter.status == state ? nil : state }) {
                        StatusMark(status: state, size: scale(Size.statusMarkSmall))
                        Text("\(model.count(of: state))")
                    }
                    .accessibilityLabel("\(state.label), \(model.count(of: state))")
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.leading, scale(Space.base)).padding(.trailing, SidebarRowLayout.trailingInset(scale))
        .padding(.bottom, scale(Space.tight))
        .listRowSeparator(.hidden)
    }

    private func command(_ selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)), model.rowFilter.isActive else { return false }
        model.rowFilter = RowFilter()
        return true
    }
}

/// A filter chip: a pill that shows its count, washed in the accent while it is the one chosen.
private struct FilterChip<Label: View>: View {
    let selected: Bool
    let help: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @Environment(\.interfaceScale) private var scale
    @Environment(\.surface) private var surface

    var body: some View {
        Button(action: action) {
            HStack(spacing: scale(Space.tight)) { label() }
                .font(Typography.help)
                .foregroundStyle(selected ? Palette.accent : surface.secondaryInk)
                .padding(.horizontal, scale(Space.base))
                .frame(height: scale(Size.slot))
                .background(Capsule().fill(selected ? Palette.selectionWash : surface.badgeWash))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// What the panel says when the filter leaves nothing.
struct FilterEmptyLine: View {
    @Environment(\.interfaceScale) private var scale
    static let text = "Nothing matches."

    var body: some View {
        RowCaption(Self.text)
            .frame(height: scale(Size.menuRow))
            .padding(.leading, scale(Space.base))
            .listRowSeparator(.hidden)
    }
}
