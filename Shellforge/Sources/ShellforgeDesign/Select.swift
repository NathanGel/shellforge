// Ported from AiTerm (app/Sources/AiTermUI/Select.swift), GPLv3, Laurens D'Hondt.
import SwiftUI
import AppKit

/// A real `NSPopUpButton`. Its menu is a window of its own, so it opens *over* whatever is below it
/// instead of pushing the sheet around, and it fills the column it is given — which neither
/// SwiftUI's menu-style `Picker` nor `Menu` will do: both hug their widest title and centre
/// themselves in the space left over.
public struct Select<Value: Hashable>: View {
    let values: [Value]
    @Binding var selection: Value
    var label: (Value) -> String
    var detail: (Value) -> String? = { _ in nil }
    var monospaced = false

    public init(values: [Value], selection: Binding<Value>, label: @escaping (Value) -> String,
                detail: @escaping (Value) -> String? = { _ in nil }, monospaced: Bool = false) {
        self.values = values
        self._selection = selection
        self.label = label
        self.detail = detail
        self.monospaced = monospaced
    }

    public var body: some View {
        NativePopUp(titles: values.map(label), tooltips: values.map(detail),
                    selectedIndex: values.firstIndex(of: selection) ?? 0, monospaced: monospaced) { index in
            if values.indices.contains(index) { selection = values[index] }
        }
        // SwiftUI pushes this environment value onto the button after `makeNSView`, so the `.large`
        // set there is not enough on its own: without it the button came back `.regular` and drew
        // a 24 pt bezel centred in the 28 pt slot, shorter than the `Input` beside it.
        .controlSize(.large)
        .frame(maxWidth: .infinity)
        .frame(height: Size.control)
    }
}

struct NativePopUp: NSViewRepresentable {
    let titles: [String]
    let tooltips: [String?]
    let selectedIndex: Int
    let monospaced: Bool
    let onSelect: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        // `.large` *is* 28 pt, which is the height `sizeThatFits` hands back. At `.regular` AppKit
        // drew a ~21 pt bezel stretched into a 28 pt slot.
        button.controlSize = .large
        // Without these the button refuses to shrink below its widest title, and a long model name
        // would push the whole row wider than the sheet.
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.onSelect = onSelect
        let font = (monospaced ? Typography.monoCode : Typography.body).nsFont
        if button.font != font { button.font = font }
        let tips = tooltips.map { $0?.isEmpty == false ? $0 : nil }
        if button.itemArray.map(\.title) != titles {
            // Built item by item, not with `addItem(withTitle:)`: that drops a title already in the
            // menu, and two models can share a label.
            button.removeAllItems()
            for (title, tip) in zip(titles, tips) {
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.toolTip = tip
                button.menu?.addItem(item)
            }
        } else {
            for (item, tip) in zip(button.itemArray, tips) where item.toolTip != tip { item.toolTip = tip }
        }
        if titles.indices.contains(selectedIndex), button.indexOfSelectedItem != selectedIndex {
            button.selectItem(at: selectedIndex)
        }
        // SwiftUI pushes this onto a hosted control today; setting it keeps `.disabled(…)` around a
        // `Select` from depending on that.
        if button.isEnabled != context.environment.isEnabled { button.isEnabled = context.environment.isEnabled }
    }

    /// Take the width offered rather than the intrinsic one: this is what makes the popup fill its
    /// column instead of hugging its title.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: Size.control)
    }

    @MainActor
    final class Coordinator: NSObject {
        var onSelect: (Int) -> Void
        init(onSelect: @escaping (Int) -> Void) { self.onSelect = onSelect }
        @objc func changed(_ sender: NSPopUpButton) { onSelect(sender.indexOfSelectedItem) }
    }
}
