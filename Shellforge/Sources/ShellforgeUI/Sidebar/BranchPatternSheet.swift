import ShellforgeCore
import ShellforgeDesign
import SwiftUI

/// Branch Names › Custom…: the pattern New Task names a project's branches by, with what it gives
/// for a sample task, with a ticket and without one, as it is typed.
struct BranchPatternSheet: View {
    static let subtitle = "New Task names this project’s branches by this pattern."
    static let legend = "{type} feat, fix or chore · {key} or {KEY} the ticket key · {slug} the task name"

    let projectName: String
    let submit: (String) -> Void
    let dismiss: @MainActor () -> Void
    // `@State` is a macro in the macOS 26 SDK and its SwiftUIMacros plugin ships only with Xcode;
    // this is the storage and accessor the macro would generate.
    private var _pattern: State<String>
    private var pattern: String {
        get { _pattern.wrappedValue }
        nonmutating set { _pattern.wrappedValue = newValue }
    }

    init(projectName: String, initialPattern: String, submit: @escaping (String) -> Void, dismiss: @escaping @MainActor () -> Void) {
        self.projectName = projectName; self.submit = submit; self.dismiss = dismiss
        _pattern = State(initialValue: initialPattern)
    }

    /// What `pattern` gives a sample task, with its ticket and without: a pattern with nothing to
    /// say without one falls back to Type and Name, as New Task does.
    static func examples(_ pattern: String) -> [String] {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        let withTicket = BranchPattern.render(trimmed, type: .feat, key: "ABC-123", summary: "Add login page")
        let withoutTicket = BranchPattern.render(trimmed, type: .feat, key: nil, summary: "Add login page")
        return ["With ticket ABC-123: \(withTicket)",
                withoutTicket.isEmpty ? "Without a ticket: feat/add-login-page (Type and Name)" : "Without a ticket: \(withoutTicket)"]
    }

    var body: some View {
        SheetLayout(title: "Branch names for \(projectName)", height: nil) {
            SheetSubtitle(Self.subtitle)
        } content: {
            FormField("Pattern") {
                Input(placeholder: BranchPattern.typeAndName, text: _pattern.projectedValue, monospaced: true)
                HelpText(Self.legend)
                if let problem = BranchPattern.problem(pattern) {
                    HelpText(problem, tone: .warning)
                } else {
                    ForEach(Self.examples(pattern), id: \.self) { HelpText($0) }
                }
            }
        } footer: {
            SheetFooter(primary: "Save", canSubmit: BranchPattern.problem(pattern) == nil,
                        cancel: { Task { @MainActor in dismiss() } }, submit: confirm)
        }
    }

    private func confirm() {
        guard BranchPattern.problem(pattern) == nil else { return }
        submit(pattern.trimmingCharacters(in: .whitespaces))
        Task { @MainActor in dismiss() }
    }
}
