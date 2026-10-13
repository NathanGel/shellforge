// Ported from AiTerm (app/Sources/AiTerm/Views/NameSheet.swift), GPLv3, Laurens D'Hondt.
import ShellforgeCore
import ShellforgeDesign
import SwiftUI

/// One field, one name. The sheet behind New Terminal, Add Divider and the renames of a task, a
/// review, a terminal and a divider: every flow whose whole question is "what should this be
/// called?". The name reaches `submit` trimmed; what an empty one means is the caller's business.
struct NameSheet: View {
    let title: String
    let subtitle: String
    let fieldLabel: String
    let placeholder: String
    let help: String?
    let confirmLabel: String
    let submit: (String) -> Void
    let dismiss: @MainActor () -> Void
    // `@State` is a macro in the macOS 26 SDK and its SwiftUIMacros plugin ships only with Xcode;
    // this is the storage and accessor the macro would generate.
    private var _name: State<String>
    private var name: String {
        get { _name.wrappedValue }
        nonmutating set { _name.wrappedValue = newValue }
    }

    init(title: String, subtitle: String, fieldLabel: String, placeholder: String, help: String? = nil,
         confirmLabel: String, initialName: String, submit: @escaping (String) -> Void, dismiss: @escaping @MainActor () -> Void) {
        self.title = title; self.subtitle = subtitle; self.fieldLabel = fieldLabel; self.placeholder = placeholder
        self.help = help; self.confirmLabel = confirmLabel; self.submit = submit; self.dismiss = dismiss
        _name = State(initialValue: initialName)
    }

    var body: some View {
        SheetLayout(title: title, height: Sheet.height) {
            SheetSubtitle(subtitle)
        } content: {
            FormField(fieldLabel) {
                Input(placeholder: placeholder, text: _name.projectedValue)
                if let help { HelpText(help) }
            }
        } footer: {
            SheetFooter(primary: confirmLabel, cancel: { Task { @MainActor in dismiss() } }, submit: confirm)
        }
    }

    private func confirm() {
        submit(name.trimmingCharacters(in: .whitespacesAndNewlines))
        Task { @MainActor in dismiss() }
    }
}

extension NameSheet {
    /// AiTerm's New terminal: the name the row carries, and nothing else — it opens a shell in the
    /// project folder and starts no agent.
    static func newTerminal(projectName: String, suggestedName: String, create: @escaping (String) -> Void,
                            dismiss: @escaping @MainActor () -> Void) -> NameSheet {
        NameSheet(title: "New terminal in \(projectName)", subtitle: "Opens a shell in the project folder.",
                  fieldLabel: "Terminal name", placeholder: "Terminal", confirmLabel: "Create Terminal",
                  initialName: suggestedName, submit: create, dismiss: dismiss)
    }
}
