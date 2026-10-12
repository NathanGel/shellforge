// Ported from AiTerm (app/Sources/AiTerm/Views/SearchPicker.swift), GPLv3, Laurens D'Hondt.
import AppKit
import ShellforgeCore
import ShellforgeDesign
import SwiftUI

/// A field with its results hanging under it: the ticket picker, the merge request picker and the
/// branch picker are the same shape. Results overlay the field rather than pushing the rest of the
/// sheet down — the whole point of a dropdown — and the `FormField` it sits in draws them over the
/// lines after it.
///
/// The highlighted row and the field's focus are the picker's own: the pointer moving down the
/// list redraws the picker, not the sheet around it — which would rank or filter its items again.
/// The caller keeps `open`, because the sheet closes the list from outside: ⎋, and a click past it.
///
/// Stays a pattern rather than a primitive: it encodes this app's decision to hang results under a
/// field instead of in a window of its own.
struct SearchPicker<Item: Identifiable, Row: View, Selected: View>: View {
    let placeholder: String
    @Binding var query: String
    @Binding var open: Bool
    let items: [Item]
    let selection: Item?
    /// A result's content, drawn on the ground its row declares — the accent while highlighted.
    let row: (Item) -> Row
    let selected: (Item) -> Selected
    let onPick: (Item) -> Void
    /// The toggle's tooltip, given whether the list is currently open. Each picker words this for
    /// what it lists — "Show my open tickets" reads wrong above a branch list.
    let toggleHelp: (Bool) -> String
    // `@State` is a macro in the macOS 26 SDK and its SwiftUIMacros plugin ships only with Xcode;
    // these are the storage and accessors the macro would generate. Private, and so kept out of
    // the initialiser: no caller seeds the picker's own state.
    private var _index = State(initialValue: 0)
    private var index: Int { get { _index.wrappedValue } nonmutating set { _index.wrappedValue = newValue } }
    private var _focused = State(initialValue: false)
    private var focused: Bool { get { _focused.wrappedValue } nonmutating set { _focused.wrappedValue = newValue } }
    /// At most six rows, as the ticket list has always shown.
    static var visibleLimit: Int { 6 }

    init(placeholder: String, query: Binding<String>, open: Binding<Bool>, items: [Item], selection: Item?,
         row: @escaping (Item) -> Row, selected: @escaping (Item) -> Selected,
         onPick: @escaping (Item) -> Void, toggleHelp: @escaping (Bool) -> String) {
        self.placeholder = placeholder; self._query = query; self._open = open
        self.items = items; self.selection = selection
        self.row = row; self.selected = selected; self.onPick = onPick; self.toggleHelp = toggleHelp
    }

    private var visible: [Item] { Array(items.prefix(Self.visibleLimit)) }

    var body: some View {
        Group {
            if let selection {
                selected(selection)
            } else {
                SearchField(placeholder: placeholder,
                            text: Binding(get: { query }, set: { query = $0; open = true; index = 0 }),
                            focused: _focused.projectedValue,
                            onCommand: command)
                    .fieldChrome(focused: focused)
                    .overlay(alignment: .trailing) { toggle.padding(.trailing, Space.tight) }
                    .overlay(alignment: .topLeading) { results.offset(y: Size.control + Space.tight) }
            }
        }
        // New results start the highlight over, at their first row.
        .onChange(of: items.map(\.id)) { _ in index = 0 }
        // Every way of opening the list — typing, the chevron or clearing a picked item — gives the
        // field the keyboard, so arrows cannot fall through to the sheet's other controls.
        .onAppear { if open { index = 0; focused = true } }
        .onChange(of: open) { open in
            if open { index = 0; focused = true }
        }
    }

    /// The way to the default list without typing, and the way back to it once ⎋ or a click past
    /// it has closed the list.
    private var toggle: some View {
        Button { open.toggle(); if open { index = 0 } } label: {
            Image(systemName: "chevron.down")
                .font(Typography.micro).foregroundStyle(Palette.muted)
                .rotationEffect(.degrees(open ? 180 : 0))
                .frame(width: Size.menuRow, height: Size.control)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(toggleHelp(open))
    }

    @ViewBuilder private var results: some View {
        if open, !visible.isEmpty, selection == nil {
            DropdownList(items: visible, index: _index.projectedValue, onPick: pick, row: row)
        }
    }

    private func command(_ selector: Selector) -> Bool {
        switch DropdownKeys.handle(selector: selector, count: visible.count, index: index, open: open && selection == nil) {
        case .moved(let i): index = i; return true
        case .accepted(let i): pick(visible[i]); return true
        case .closed: open = false; index = 0; return true
        case .unhandled: return false
        }
    }

    private func pick(_ item: Item) {
        onPick(item)
        query = ""
        open = false
        index = 0
    }
}

// -- the parts every picker draws -------------------------------------------------
//
// Patterns, not primitives: arranged from `Icon`, `Text` and `fieldChrome`, and read only by
// `SearchPicker`'s callers for its rows and its pick — see the README on why they are not promoted.

/// A picker's pick, drawn in its field's place: the service's mark, the key in the link colour, the
/// title, anything `trailing`, and the ✕ that clears it back to the search field. The ticket, merge
/// request, Jira project and branch pickers all draw their pick this way.
struct PickedItemField<Trailing: View>: View {
    let mark: IconSource?
    let key: String?
    let title: String
    /// A branch name, which has no mark or key: set in the code face and cut in the middle, so both
    /// its prefix and its distinguishing end survive.
    let monospaced: Bool
    let trailing: Trailing
    let clearHelp: String
    let clear: () -> Void

    init(mark: IconSource? = nil, key: String? = nil, title: String, monospaced: Bool = false,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() }, clearHelp: String, clear: @escaping () -> Void) {
        self.mark = mark; self.key = key; self.title = title; self.monospaced = monospaced
        self.trailing = trailing(); self.clearHelp = clearHelp; self.clear = clear
    }

    var body: some View {
        HStack(spacing: Space.base) {
            if let mark { Icon(mark, size: Size.pickerLogo) }
            if let key { Text(key).font(Typography.monoCode).foregroundStyle(Palette.link) }
            Text(title).font(monospaced ? Typography.monoCode : Typography.body).foregroundStyle(Palette.text)
                .lineLimit(1).truncationMode(monospaced ? .middle : .tail)
            Spacer(minLength: Space.snug)
            trailing
            Button(action: clear) {
                Image(systemName: "xmark").font(Typography.micro).foregroundStyle(Palette.muted)
            }.buttonStyle(.plain).help(clearHelp)
        }
        .fieldChrome()
    }
}

/// A result row of the ticket, merge request and Jira project pickers: the service's mark, a key
/// in a column of `keyWidth` so the titles after it start on one line, the title, and a trailing
/// `detail` — a ticket's or merge request's lane. Inked for the ground its row declares: on the
/// accent everything turns white, as in the prompt's command-and-skill popup; off it, the mark and
/// the key keep the service's colours.
struct PickerResultRow: View {
    let mark: IconSource
    let key: String
    let keyWidth: CGFloat
    let title: String
    /// `nil` draws no detail column at all; an empty string keeps the column, and its spacing, empty.
    let detail: String?
    @Environment(\.surface) private var surface

    var body: some View {
        HStack(spacing: Space.base) {
            Icon(mark, size: Size.pickerRowLogo, tint: Self.logoTint(on: surface))
            Text(key).font(Typography.monoCode).foregroundStyle(Self.keyInk(on: surface))
                .frame(width: keyWidth, alignment: .leading)
            Text(title).font(Typography.caption).foregroundStyle(surface.ink).lineLimit(1)
            Spacer(minLength: Space.snug)
            if let detail { Text(detail).font(Typography.help).foregroundStyle(surface.secondaryInk) }
        }
    }

    /// The mark's tint: white on the accent, else `nil`, its brand colour.
    static func logoTint(on surface: Surface) -> Color? { surface.isOnAccent ? surface.ink : nil }
    /// The key: white on the accent, else the link colour.
    static func keyInk(on surface: Surface) -> Color { surface.isOnAccent ? surface.ink : Palette.link }
}

/// A picked ticket's or merge request's lane, on its service's own wash rather than amber: amber
/// is this app's "needs attention" colour (drifted branch, needs-input chip, usage ≥ 80 %), and a
/// lane name is neutral information about the item, not a warning about the task.
///
/// Not a `Badge`: a badge sets its label in the mono chip face on a neutral wash, and this is a
/// word in the label face on a brand's.
struct LaneChip: View {
    let lane: String
    let brand: Brand
    /// Jira's lanes read in the link blue its keys use; GitLab's in its own orange.
    let ink: Color

    var body: some View {
        Text(lane).font(Typography.label)
            .padding(.horizontal, Space.snug).frame(height: Size.chip)
            .background(RoundedRectangle(cornerRadius: Radius.chip).fill(brand.wash))
            .foregroundStyle(ink)
    }
}
