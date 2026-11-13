import AppKit
import ShellforgeCore
import ShellforgeDesign
import SwiftUI

/// Add Host's state: the host being typed, the project it is for, and what stops it being added —
/// `SSHConfigAppender.problem` against the hosts the sidebar last read, or the last add's failure
/// until the next edit.
@MainActor
final class AddHostModel: ObservableObject {
    static let createdNote = "Created ~/.ssh/config."
    static let replaceTitle = "Replace"

    @Published var draft = NewSSHHost(alias: "", hostName: "") {
        didSet { if draft != oldValue { failure = nil } }
    }
    /// The project whose SSH host it becomes; nil for none.
    @Published var project: UUID?
    /// Why the last add failed, in the appender's words; cleared by an edit.
    @Published private(set) var failure: String?
    /// While the append runs nothing in the sheet can be changed.
    @Published private(set) var adding = false
    /// One line for the sidebar after an add that made the config: nil when it was there already.
    private(set) var note: String?
    /// What a `Host *` or `Match all` block in the config sets, as last read.
    @Published private(set) var earlierDefaults: [SSHWildcardDefault] = []
    let sidebar: SidebarModel

    init(sidebar: SidebarModel) { self.sidebar = sidebar }

    /// The projects the host can be for, in the sidebar's order.
    var projects: [(id: UUID, name: String)] { sidebar.document.workspace.projects.map { ($0.id, $0.name) } }

    /// Where Choose… opens: the config's own folder, `~/.ssh`.
    var identityFolder: URL { sidebar.sshConfig.file.deletingLastPathComponent() }

    /// What the sheet shows for the host as typed: checked once per render.
    struct Status: Equatable {
        /// What the problem line says: the last failure, else what is wrong with the host as typed.
        var problem: String?
        /// Add is offered once the host as typed can be added. A failure alone doesn't grey it: the
        /// person may fix its cause (a folder's permissions) and try again.
        var canAdd: Bool
        /// A caution that doesn't stop Add: an earlier `Host *` block already sets what this host sets.
        var warning: String?
    }

    var status: Status {
        let typed = typedProblem
        return Status(problem: failure ?? typed, canAdd: typed == nil && !adding,
                      warning: SSHConfig.wildcardWarning(for: draft, earlier: earlierDefaults))
    }

    var problem: String? { status.problem }

    var canAdd: Bool { status.canAdd }

    private var typedProblem: String? {
        SSHConfigAppender.problem(with: draft, existing: sidebar.sshHosts.map { Array($0.values) } ?? [])
    }

    /// A chosen key file as the IdentityFile line has it: `~` for the home folder, else absolute.
    nonisolated static func identityPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    /// Reads the config again, off the main actor, so the problem line checks against it as it is.
    func load() async {
        _ = await sidebar.loadSSHHosts()
        let source = sidebar.sshConfig
        earlierDefaults = await BackgroundWork.run { source.wildcardDefaults() }
    }

    /// Appends the host off the main actor. On success it becomes the chosen project's SSH host —
    /// asked first when that project names another — the config is read again and watched (a
    /// `~/.ssh` just made is watched from now on), and true is returned for the sheet to close. On a
    /// failure its words are the problem line and the sheet stays.
    func add() async -> Bool {
        guard canAdd else { return false }
        adding = true
        defer { adding = false }
        let host = draft
        let source = sidebar.sshConfig
        let outcome = await BackgroundWork.run { () -> Result<AppendResult, SSHConfigAppendError> in
            do { return .success(try SSHConfigAppender.append(host, to: source)) } catch let error as SSHConfigAppendError {
                return .failure(error)
            } catch {
                return .failure(.writeFailed(error.localizedDescription))
            }
        }
        let result: AppendResult
        switch outcome {
        case .success(let appended): result = appended
        case .failure(let error):
            failure = error.errorDescription
            return false
        }
        let alias = host.trimmed.alias
        if let project { await makeHost(alias, of: project) }
        _ = await sidebar.loadSSHHosts()
        sidebar.watchSSHConfig()
        if result.created {
            note = Self.createdNote
            sidebar.show(notice: Self.createdNote)
        }
        return true
    }

    /// `alias` as the project's SSH host; when it already names another, only if the person says so.
    private func makeHost(_ alias: String, of projectId: UUID) async {
        guard let current = sidebar.project(projectId) else { return }
        if let old = current.sshHost, old != alias {
            let prompt = AlertPrompt(message: "Replace \(old) as \(current.name)’s SSH host?",
                                     buttons: [Self.replaceTitle, "Keep \(old)"], escape: 1)
            guard await sidebar.prompter.ask(prompt).confirmed else { return }
        }
        sidebar.setSSHHost(alias, on: projectId)
    }
}

/// Add Host, from the SSH panel: a host appended to `~/.ssh/config`, after a backup, optionally
/// made a project's SSH host.
struct AddHostSheet: View {
    static let title = "Add SSH Host"
    static let subtitle = "Adds a host to your SSH config."
    static let footnote = "Added to ~/.ssh/config. The file is copied to config.shellforge-backup first."
    static let noProject = "None"

    @ObservedObject var model: AddHostModel
    /// The sidebar, watched so the problem line follows the config as it is read again.
    @ObservedObject var sidebar: SidebarModel
    let dismiss: @MainActor () -> Void

    init(model: AddHostModel, dismiss: @escaping @MainActor () -> Void) {
        self.model = model
        self.sidebar = model.sidebar
        self.dismiss = dismiss
    }

    var body: some View {
        let status = model.status
        return SheetLayout(title: Self.title, height: nil, locked: model.adding) {
            SheetSubtitle(Self.subtitle)
        } content: {
            VStack(alignment: .leading, spacing: Space.block) {
                FormField("Name") { Input(placeholder: "staging", text: $model.draft.alias, monospaced: true) }
                FormField("Address (HostName)") { Input(placeholder: "staging.example.com", text: $model.draft.hostName, monospaced: true) }
                HStack(alignment: .top, spacing: Space.block) {
                    FormField("User") { Input(placeholder: "deploy", text: $model.draft.user, monospaced: true) }
                    FormField("Port") { Input(placeholder: "22", text: $model.draft.port, monospaced: true) }
                        .frame(width: Size.control * 3)
                }
                FormField("Identity file") {
                    HStack(spacing: Space.base) {
                        Input(placeholder: "~/.ssh/id_ed25519", text: $model.draft.identityFile, monospaced: true)
                        Button("Choose…", action: chooseIdentity)
                    }
                }
                FormField("For project") {
                    Picker("For project", selection: $model.project) {
                        Text(Self.noProject).tag(UUID?.none)
                        ForEach(model.projects, id: \.id) { project in Text(project.name).tag(UUID?.some(project.id)) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                if let problem = status.problem { HelpText(problem, tone: .warning) }
                if status.problem == nil, let warning = status.warning { HelpText(warning, tone: .warning) }
                HelpText(Self.footnote)
            }
        } footer: {
            SheetFooter(primary: "Add", canCancel: !model.adding, canSubmit: status.canAdd,
                        cancel: { Task { @MainActor in dismiss() } }, submit: submit)
        }
        .task { await model.load() }
    }

    private func submit() {
        Task { @MainActor in
            if await model.add() { dismiss() }
        }
    }

    /// The key file, picked in a panel that starts in `~/.ssh`; written with `~` for the home folder.
    private func chooseIdentity() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = model.identityFolder
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.draft.identityFile = AddHostModel.identityPath(url)
    }
}
