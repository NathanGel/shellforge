import AppKit
import ShellforgeCore
import ShellforgeDesign
import SwiftUI

/// Settings › Agents' form, in the Settings panel in place of its sections: Name, Command, how the
/// first prompt gets in, environment variables, secrets and status. Save writes the agent and
/// closes it; a Save that can't go through says why and keeps it open. Cancel leaves the agent as
/// it was last saved — including by an earlier Save in this form whose secret the Keychain refused.
struct AgentFormView: View {
    @ObservedObject var model: AgentFormModel
    let close: @MainActor () -> Void
    @State private var failure: String?

    var body: some View {
        SheetLayout(title: model.title, height: Sheet.settingsHeight) {
            SheetSubtitle("The command Shellforge types to start the agent, what it starts with, and how its status is read.")
        } content: {
            VStack(alignment: .leading, spacing: Space.section) {
                nameField
                commandField
                promptField
                variables
                secretFields
                if model.showsStatusChoice { statusField }
            }
        } footer: {
            SheetFooter(primary: "Save", canSubmit: model.canSave, cancel: { Task { @MainActor in close() } }, submit: save) {
                if let failure {
                    Text(failure).font(Typography.caption).foregroundStyle(Palette.amber).lineLimit(2).help(failure)
                }
            }
        }
    }

    private func save() {
        do {
            try model.save()
            failure = nil
            Task { @MainActor in close() }
        } catch {
            failure = error.localizedDescription
        }
    }

    /// A field's problem under it, or what the field is for.
    @ViewBuilder
    private func note(_ problem: String?, else help: String? = nil) -> some View {
        if let problem {
            HelpText(problem, tone: .warning)
        } else if let help {
            HelpText(help)
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            FormField("Name") { Input(placeholder: "My agent", text: $model.name) }
            note(model.nameProblem)
            if let about = model.about { HelpText(about) }
        }
    }

    private var commandField: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            FormField("Command") { Input(placeholder: "agent --model {model}", text: $model.command, monospaced: true) }
            note(model.commandProblem, else: "The program, then its fixed arguments. {model}, {reasoning} and {cwd} are filled in when a task starts.")
        }
    }

    private var promptField: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            FormField("How the first prompt gets in") {
                SegmentedControl(values: AgentFormModel.PromptMode.allCases, selection: $model.promptMode) { mode, _ in
                    Text(mode.title).font(Typography.caption)
                }
            }
            if model.promptMode == .argument {
                Input(placeholder: "-p {prompt}", text: $model.promptArguments, monospaced: true)
                note(model.promptProblem, else: "A long or awkward prompt goes through .shellforge/first-prompt.md.")
            } else if model.promptMode == .typed {
                HelpText("Shellforge starts the agent, waits until it is ready, then types the prompt and Return.")
            }
            if let preview = model.preview {
                Text(preview).font(Typography.mono).foregroundStyle(Palette.muted).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func removeButton(_ remove: @escaping () -> Void) -> some View {
        Button(action: remove) { Image(symbol: .minusCircle) }.buttonStyle(.borderless).help("Remove")
    }

    private var variables: some View {
        FormField("Environment variables") {
            VStack(alignment: .leading, spacing: Space.snug) {
                ForEach($model.environment) { $variable in
                    HStack(spacing: Space.base) {
                        Input(placeholder: "NAME", text: $variable.name, monospaced: true)
                        Input(placeholder: "Value", text: $variable.value, monospaced: true)
                        removeButton { [id = variable.id] in model.environment.removeAll { $0.id == id } }
                    }
                }
                Button("Add Variable") { model.environment.append(.init(name: "", value: "")) }
            }
        }
    }

    private var secretFields: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            FormField("Secrets") {
                VStack(alignment: .leading, spacing: Space.snug) {
                    ForEach($model.secrets) { $secret in
                        HStack(spacing: Space.base) {
                            Input(placeholder: "NAME", text: $secret.name, monospaced: true)
                            // A secure field: what is typed is hidden, and a stored value is never shown.
                            Input(placeholder: secret.stored ? "Saved in the Keychain" : "Value", text: $secret.value, secure: true)
                            removeButton { [id = secret.id] in model.secrets.removeAll { $0.id == id } }
                        }
                    }
                    Button("Add Secret") { model.secrets.append(.init(name: "", value: "", stored: false)) }
                }
            }
            note(model.variableProblem, else: "Secrets are kept in the Keychain and set only when the agent starts.")
        }
    }

    private var statusField: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            FormField("Status") {
                SegmentedControl(values: AgentFormModel.StatusMode.allCases, selection: $model.status) { mode, _ in
                    Text(mode.title).font(Typography.caption)
                }
            }
            if model.status == .automatic {
                HelpText("Guessed from the agent’s terminal. There is nothing to set up.")
            } else {
                exactSetup
            }
        }
    }

    @ViewBuilder
    private var exactSetup: some View {
        if let warning = model.setupWarning {
            HelpText(warning, tone: .warning)
        } else if let lines = model.setupLines {
            HelpText(model.setupFile.map { "Add these lines to \($0):" } ?? "Run these from the agent’s hooks, one for each state:")
            if let note = model.setupNote { HelpText(note) }
            Text(lines).font(Typography.mono).foregroundStyle(Palette.text).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.base)
                .background(RoundedRectangle(cornerRadius: Radius.control).fill(Palette.groupFill))
            HStack(spacing: Space.base) {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(lines, forType: .string)
                }
                Button("Test") { model.test() }
                if let message = model.testMessage { HelpText(message) }
            }
        }
    }
}
