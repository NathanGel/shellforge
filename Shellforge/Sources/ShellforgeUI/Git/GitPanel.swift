import AppKit
import ShellforgeCore
import ShellforgeDesign
import SwiftUI

/// One of the three lists a repository's changes fall in.
enum GitChangeList: String, CaseIterable, Sendable {
    case merge, staged, changes

    var title: String {
        switch self {
        case .merge: "Merge Changes"
        case .staged: "Staged Changes"
        case .changes: "Changes"
        }
    }

    func changes(_ status: GitStatus) -> [GitChange] {
        switch self {
        case .merge: status.conflicted
        case .staged: status.staged
        case .changes: status.unstaged
        }
    }
}

/// What the Git panel does for one window: diffs and files open in that window's tabs, and its
/// questions are asked over that window. The app's one `GitModel` does the git work.
@MainActor
struct GitPanelActions {
    let host: TerminalHost
    /// The app's own suite, where Settings › Core › Terminal editor is saved.
    let defaults: UserDefaults
    let environment: @Sendable () -> [String: String]
    let launcher: CommandLauncher
    /// The window's prompter, read when a question is asked.
    let prompter: @MainActor () -> Prompter
    /// The title of a task with open tabs working in a project's own folder, if any.
    let busyTask: @MainActor (UUID) -> String?
    var kind: @Sendable (String) -> FileKind = FileKind.onDisk

    /// A change's diff, in a new tab in its repository. The tab keeps its shell after the pager:
    /// git's `less -FRX` quits at once on a short diff, which would close a tab that ran it with `exec`.
    func viewDiff(_ change: GitChange, list: GitChangeList, in section: GitSection) {
        let name = (change.path as NSString).lastPathComponent
        host.openTab(in: section.path, title: "Diff: \(name)", command: GitActions.diffLine(for: change, staged: list == .staged))
    }

    /// A changed file in the terminal editor, as the Files panel opens one. A file no longer there
    /// opens nothing: its repository is read again.
    func openInEditor(_ change: GitChange, in section: GitSection, model: GitModel) async {
        let path = URL(fileURLWithPath: section.path).appendingPathComponent(change.path).path
        let (kind, environment) = (self.kind, self.environment)
        let (found, variables) = await BackgroundWork.run { () -> (FileKind, [String: String]) in
            let found = kind(path)
            return (found, found == .file ? environment() : [:])
        }
        guard found == .file else {
            await model.refresh(section.id)
            return
        }
        let editor = EditorCommand.editor(setting: defaults.string(forKey: EditorCommand.settingKey), environment: variables)
        host.openTab(in: section.path, title: (change.path as NSString).lastPathComponent,
                     command: EditorCommand.line(editor: editor, file: change.path))
    }

    /// Asks first; a Cancel discards nothing.
    func discard(_ change: GitChange, in section: GitSection, model: GitModel) async {
        guard await model.confirmDiscard(change, prompter: prompter()) else { return }
        await model.perform(.discard(change), in: section.id)
    }

    /// Switches a project's folder, asking what New Task asks for a Project folder task.
    func switchBranch(_ section: GitSection, to branch: String, model: GitModel) async {
        guard case .project(let project) = section.id else { return }
        let flow = BranchSwitchFlow(prompter: prompter(), launcher: launcher)
        let busyTask = self.busyTask
        await model.switchBranch(section.id, to: branch, flow: flow, busyTask: { busyTask(project) })
    }
}

/// The Git panel: one section per workspace project, in the workspace's order — its row (provider
/// mark, chevron, name) folds it — then its branch, commit message and changes; under it, each of
/// its tasks with changes, the same way but for Switch Branch. `titled` false when the title is
/// pinned above the panel instead.
struct GitPanel: View {
    @ObservedObject var model: GitModel
    let titled: Bool
    var providers: [UUID: Provider] = [:]
    let actions: GitPanelActions
    /// Folded sections, for this window only.
    @State private var folded: Set<GitRepoID> = []

    /// The panel's `ViewMark`.
    static let markName = "GitPanel"

    static let loadingText = "Loading…"
    static let missingText = "Folder not found"
    static let notARepositoryText = "Not a git repository"

    /// One line of the panel.
    struct Row: Identifiable, Equatable {
        enum Kind: Equatable {
            case title(open: Bool)
            case message(String, warns: Bool)
            case branch(GitStatus)
            case problem(String)
            case commit(GitStatus)
            case list(GitChangeList, [GitChange])
            case change(GitChangeList, GitChange)
        }

        var section: GitSection
        var kind: Kind
        var id: String
    }

    static func key(_ repo: GitRepoID) -> String {
        switch repo {
        case .project(let id): "project:" + id.uuidString
        case .task(let id): "task:" + id.uuidString
        }
    }

    static func titleID(_ repo: GitRepoID) -> String { key(repo) + ":title" }

    /// A change's row: qualified by its list, as a file both staged and changed again is in two.
    static func changeID(_ repo: GitRepoID, _ list: GitChangeList, _ change: GitChange) -> String {
        "\(key(repo)):\(list.rawValue):\(change.id)"
    }

    /// The rows drawn: a folded section contributes no rows below its own, and a folded project
    /// none of its tasks'.
    static func rows(_ sections: [GitSection], isOpen: (GitRepoID) -> Bool) -> [Row] {
        sections.flatMap { project -> [Row] in
            let open = isOpen(project.id)
            var rows = sectionRows(project, open: open)
            guard open else { return rows }
            for task in project.tasks { rows += sectionRows(task, open: isOpen(task.id)) }
            return rows
        }
    }

    private static func sectionRows(_ section: GitSection, open: Bool) -> [Row] {
        var plain = section
        plain.tasks = []
        let key = key(section.id)
        func row(_ kind: Row.Kind, _ id: String) -> Row { Row(section: plain, kind: kind, id: key + ":" + id) }
        var rows = [Row(section: plain, kind: .title(open: open), id: titleID(section.id))]
        guard open else { return rows }
        let problem = section.problem.map { row(.problem($0), "problem") }
        switch section.state {
        case .loading:
            rows.append(row(.message(loadingText, warns: false), "message"))
            rows += [problem].compactMap { $0 }
        case .missing:
            rows.append(row(.message(missingText, warns: true), "message"))
            rows += [problem].compactMap { $0 }
        case .notARepository:
            rows.append(row(.message(notARepositoryText, warns: false), "message"))
            rows += [problem].compactMap { $0 }
        case .status(let status):
            rows.append(row(.branch(status), "branch"))
            rows += [problem].compactMap { $0 }
            rows.append(row(.commit(status), "commit"))
            for list in GitChangeList.allCases {
                let changes = list.changes(status)
                guard !changes.isEmpty else { continue }
                rows.append(row(.list(list, changes), "list:" + list.rawValue))
                rows += changes.map { Row(section: plain, kind: .change(list, $0), id: changeID(section.id, list, $0)) }
            }
        }
        return rows
    }

    // -- what a section offers --------------------------------------------------------------

    enum RemoteAction: Equatable, CaseIterable {
        case pull, push, publish

        var title: String {
            switch self {
            case .pull: "Pull"
            case .push: "Push"
            case .publish: "Publish Branch"
            }
        }

        var action: GitAction { self == .pull ? .pull : .push }
    }

    /// “main ↑2 ↓1”: the branch, and how far it is ahead of and behind its upstream.
    static func branchLine(_ status: GitStatus) -> String {
        switch status.head {
        case .unborn: return "No commits yet"
        case .detached(let sha): return "Detached at \(sha)"
        case .branch(let name):
            let counts = (status.ahead > 0 ? ["↑\(status.ahead)"] : []) + (status.behind > 0 ? ["↓\(status.behind)"] : [])
            return ([name] + counts).joined(separator: " ")
        }
    }

    /// Pull and Push on a branch with an upstream; Publish Branch on one without. Nothing on a
    /// branch with no commit yet, or a detached head.
    static func remoteActions(_ status: GitStatus) -> [RemoteAction] {
        guard case .branch = status.head else { return [] }
        return status.upstream == nil ? [.publish] : [.pull, .push]
    }

    static func commitPlaceholder(_ status: GitStatus) -> String {
        status.staged.isEmpty ? "Message (commits all changes when none are staged)" : "Message"
    }

    static func canCommit(message: String, busy: Bool) -> Bool {
        !busy && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Only a project's own folder switches branch: a task's worktree keeps its branch.
    static func offersSwitchBranch(_ section: GitSection) -> Bool {
        guard case .project = section.id, case .status(let status) = section.state else { return false }
        if case .unborn = status.head { return false }
        return true
    }

    /// Discard is for the Changes list only, and never for a conflict.
    static func offersDiscard(_ change: GitChange, list: GitChangeList) -> Bool {
        list == .changes && change.letter != .conflicted
    }

    // -- drawing ----------------------------------------------------------------------------

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if titled { FilesPanelTitle(panel: .git) }
            List {
                ForEach(Self.rows(model.sections, isOpen: { !folded.contains($0) })) { row in
                    rowView(row).listRowSeparator(.hidden)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(NativeRowHighlight.off)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ViewMark(name: Self.markName))
    }

    @ViewBuilder private func rowView(_ row: Row) -> some View {
        let section = row.section
        let depth = section.isTask ? 1 : 0
        switch row.kind {
        case .title(let open):
            GitTitleRow(section: section, open: open, provider: provider(section), depth: depth,
                        toggle: { toggle(section.id) })
                .background(ViewMark(name: row.id))
        case .message(let text, let warns):
            GitIndented(depth: depth) { RowCaption(text, warns: warns) }
        case .problem(let text):
            GitIndented(depth: depth) {
                Text(text).font(Typography.help).foregroundStyle(Palette.destructive)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        case .branch(let status):
            GitIndented(depth: depth) {
                GitBranchLine(section: section, status: status, actions: actions, model: model)
            }
        case .commit(let status):
            GitIndented(depth: depth) {
                GitCommitBox(section: section, status: status, model: model)
            }
        case .list(let list, let changes):
            GitIndented(depth: depth) {
                GitListHeader(list: list, busy: section.busy, perform: { action in
                    Task { await model.perform(action, in: section.id) }
                }, changes: changes)
            }
        case .change(let list, let change):
            GitChangeRow(change: change, list: list, depth: depth, busy: section.busy,
                         commands: commands(change, list: list, in: section))
                .background(ViewMark(name: row.id))
        }
    }

    /// A project's provider mark; a task's row draws none.
    private func provider(_ section: GitSection) -> Provider {
        guard case .project(let id) = section.id else { return .git }
        return providers[id] ?? .git
    }

    private func toggle(_ repo: GitRepoID) {
        if folded.contains(repo) { folded.remove(repo) } else { folded.insert(repo) }
    }

    /// What a change's row does: its hover buttons, its menu and its VoiceOver actions.
    private func commands(_ change: GitChange, list: GitChangeList, in section: GitSection) -> GitChangeCommands {
        let (model, actions) = (self.model, self.actions)
        let path = URL(fileURLWithPath: section.path).appendingPathComponent(change.path).path
        return GitChangeCommands(
            viewDiff: { actions.viewDiff(change, list: list, in: section) },
            openInEditor: change.letter == .deleted ? nil : { Task { await actions.openInEditor(change, in: section, model: model) } },
            stage: list == .staged ? nil : { Task { await model.perform(.stage([change.path]), in: section.id) } },
            unstage: list == .staged ? { Task { await model.perform(.unstage([change.path]), in: section.id) } } : nil,
            discard: Self.offersDiscard(change, list: list) ? { Task { await actions.discard(change, in: section, model: model) } } : nil,
            vsCode: change.letter == .deleted ? nil : OpenIn.vsCodeItem(file: path, vsCodeInstalled: OpenIn.vsCodeInstalled))
    }
}

extension GitSection {
    var isTask: Bool {
        if case .task = id { return true }
        return false
    }
}

/// A row's content at a section's depth, lined up under its title's name.
private struct GitIndented<Content: View>: View {
    let depth: Int
    @ViewBuilder let content: () -> Content
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        HStack(spacing: 0) {
            content()
            Spacer(minLength: 0)
        }
        .frame(minHeight: scale(Size.menuRow))
        .padding(.leading, GitTitleRow.contentInset(depth: depth, scale))
        .padding(.trailing, SidebarRowLayout.trailingInset(scale))
    }
}

/// A section's row: a chevron, the project's provider mark (a task has none) and the name. A click
/// folds or unfolds the section.
private struct GitTitleRow: View {
    let section: GitSection
    let open: Bool
    let provider: Provider
    let depth: Int
    let toggle: () -> Void
    @Environment(\.interfaceScale) private var scale

    /// Where a section's rows start: past its title's chevron.
    static func contentInset(depth: Int, _ scale: InterfaceScale) -> CGFloat {
        scale(Space.base) + scale(Space.block) * CGFloat(depth) + SidebarRowLayout.chevronWidth(scale) + scale(Space.base)
    }

    var body: some View {
        HStack(spacing: scale(Space.base)) {
            HeaderChevron(collapsed: !open).frame(width: SidebarRowLayout.chevronWidth(scale))
            if !section.isTask { ProviderIcon(provider: provider) }
            if section.isTask { RowTitle(section.title) } else { HeaderTitle(text: section.title) }
            Spacer(minLength: scale(Space.tight))
        }
        .frame(height: scale(section.isTask ? Size.menuRow : Size.projectRow))
        .padding(.leading, scale(Space.base) + scale(Space.block) * CGFloat(depth))
        .padding(.trailing, SidebarRowLayout.trailingInset(scale))
        .modifier(RowPill(selected: false))
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(section.title), \(section.isTask ? "task" : "project")")
        .accessibilityValue(open ? GitChangeRow.expanded : GitChangeRow.collapsed)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { toggle() }
        .accessibilityAction(named: Text(open ? GitChangeRow.fold : GitChangeRow.unfold), toggle)
        .contextMenu { OpenInMenuItems(folder: section.path) }
    }
}

/// The branch line: the branch and how far it is from its upstream, a spinner while the section is
/// busy, and Switch Branch… on a project.
private struct GitBranchLine: View {
    let section: GitSection
    let status: GitStatus
    let actions: GitPanelActions
    @ObservedObject var model: GitModel
    @State private var choosing = false
    @Environment(\.interfaceScale) private var scale
    @Environment(\.surface) private var surface

    static let switchTitle = "Switch Branch…"
    static let branchSymbol = "arrow.triangle.branch"

    var body: some View {
        HStack(spacing: scale(Space.snug)) {
            Icon(.symbol(Self.branchSymbol), size: scale(Size.trailingGlyph), tint: surface.secondaryInk)
            Text(GitPanel.branchLine(status)).font(Typography.monoCode).foregroundStyle(surface.ink)
                .lineLimit(1).truncationMode(.middle)
                .accessibilityLabel("Branch: \(GitPanel.branchLine(status))")
            if section.busy {
                ProgressView().controlSize(.mini).accessibilityLabel("Working")
            }
            Spacer(minLength: scale(Space.tight))
            if GitPanel.offersSwitchBranch(section) {
                Button(Self.switchTitle) { choosing = true }
                    .controlSize(.small)
                    .disabled(section.busy)
                    .popover(isPresented: $choosing, arrowEdge: .bottom) {
                        GitBranchList(repo: section.path, current: Self.current(status), launcher: actions.launcher) { branch in
                            choosing = false
                            Task { await actions.switchBranch(section, to: branch, model: model) }
                        }
                    }
            }
        }
    }

    static func current(_ status: GitStatus) -> String? {
        if case .branch(let name) = status.head { return name }
        return nil
    }
}

/// Switch Branch…'s list: the repository's branches, read off the main actor, filtered as you
/// type; the current one is marked. Return picks the first match.
private struct GitBranchList: View {
    let repo: String
    let current: String?
    let launcher: CommandLauncher
    let pick: (String) -> Void
    @State private var branches: [String]?
    @State private var problem: String?
    @State private var query = ""
    @State private var focused = true

    static let placeholder = "Search branches"
    static let checkSymbol = "checkmark"
    private static let width: CGFloat = 280
    private static let listHeight: CGFloat = 220

    private var matches: [String] {
        let all = branches ?? []
        let wanted = query.trimmingCharacters(in: .whitespaces)
        return wanted.isEmpty ? all : all.filter { $0.localizedCaseInsensitiveContains(wanted) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.base) {
            SearchField(placeholder: Self.placeholder, text: $query, focused: $focused, onCommand: command)
                .fieldChrome(focused: focused)
            content.frame(height: Self.listHeight, alignment: .top)
        }
        .padding(Space.gap)
        .frame(width: Self.width)
        .task { await load() }
    }

    @ViewBuilder private var content: some View {
        if let problem {
            Text(problem).font(Typography.help).foregroundStyle(Palette.destructive)
        } else if branches == nil {
            Text(GitPanel.loadingText).font(Typography.help).foregroundStyle(Palette.muted)
        } else if matches.isEmpty {
            Text("No branches match").font(Typography.help).foregroundStyle(Palette.muted)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(matches, id: \.self) { branch in
                        Button { if branch != current { pick(branch) } } label: {
                            HStack(spacing: Space.snug) {
                                Image(systemName: Self.checkSymbol).font(Typography.micro)
                                    .opacity(branch == current ? 1 : 0)
                                Text(branch).font(Typography.monoCode).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .frame(height: Size.menuRow)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(branch == current ? "\(branch), current branch" : branch)
                    }
                }
            }
        }
    }

    private func command(_ selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        if let first = matches.first(where: { $0 != current }) { pick(first) }
        return true
    }

    private func load() async {
        let (repo, launcher) = (self.repo, self.launcher)
        do {
            branches = try await BackgroundWork.run { try GitActions.branches(in: repo, launcher: launcher) }
        } catch {
            problem = (error as? GitFailure)?.message ?? "git: \(error.localizedDescription)"
        }
    }
}

/// The commit message and the section's buttons: Commit (⌘↩ in the field), then Pull and Push, or
/// Publish Branch.
private struct GitCommitBox: View {
    let section: GitSection
    let status: GitStatus
    @ObservedObject var model: GitModel
    @State private var focused = false
    @Environment(\.interfaceScale) private var scale

    static let commitTitle = "Commit"

    private var message: Binding<String> {
        let (model, id) = (self.model, section.id)
        return Binding(get: { model.commitMessage(id) }, set: { model.setCommitMessage($0, for: id) })
    }

    private var canCommit: Bool { GitPanel.canCommit(message: model.commitMessage(section.id), busy: section.busy) }

    var body: some View {
        VStack(alignment: .leading, spacing: scale(Space.snug)) {
            SearchField(placeholder: GitPanel.commitPlaceholder(status), text: message, focused: $focused, onCommand: { _ in false })
                .fieldChrome(focused: focused)
                .accessibilityLabel("Commit message")
            HStack(spacing: scale(Space.snug)) {
                Button(Self.commitTitle) { perform(.commit) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCommit)
                    // Only the field being typed in commits: each section has a Commit button.
                    .keyboardShortcut(focused ? KeyboardShortcut(.return, modifiers: .command) : nil)
                Spacer(minLength: scale(Space.tight))
                ForEach(GitPanel.remoteActions(status), id: \.title) { remote in
                    Button(remote.title) { perform(remote.action) }.disabled(section.busy)
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, scale(Space.tight))
    }

    private func perform(_ action: GitAction) {
        let (model, id) = (self.model, section.id)
        Task { await model.perform(action, in: id) }
    }
}

/// A list's header: its name and count, and Stage All or Unstage All.
private struct GitListHeader: View {
    let list: GitChangeList
    let busy: Bool
    let perform: (GitAction) -> Void
    let changes: [GitChange]
    @Environment(\.interfaceScale) private var scale
    @Environment(\.surface) private var surface

    static let stageAll = "Stage All"
    static let unstageAll = "Unstage All"

    private var bulk: (title: String, symbol: String, action: GitAction)? {
        let paths = changes.map(\.path)
        switch list {
        case .changes: return (Self.stageAll, GitChangeRow.stageSymbol, .stage(paths))
        case .staged: return (Self.unstageAll, GitChangeRow.unstageSymbol, .unstage(paths))
        case .merge: return nil
        }
    }

    var body: some View {
        HStack(spacing: scale(Space.snug)) {
            Text(list.title.uppercased()).font(Typography.sectionHeader).foregroundStyle(surface.secondaryInk)
            Text("\(changes.count)").font(Typography.monoChip).foregroundStyle(surface.secondaryInk)
            Spacer(minLength: scale(Space.tight))
            if let bulk {
                GitIconButton(title: bulk.title, symbol: bulk.symbol) { perform(bulk.action) }.disabled(busy)
            }
        }
        .padding(.top, scale(Space.tight))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(list.title), \(changes.count)")
        .modifier(BulkAccessibility(bulk: bulk.map { bulk in (title: bulk.title, run: { perform(bulk.action) }) }))
    }
}

private struct BulkAccessibility: ViewModifier {
    let bulk: (title: String, run: () -> Void)?

    func body(content: Content) -> some View {
        if let bulk { content.accessibilityAction(named: Text(bulk.title), bulk.run) } else { content }
    }
}

/// What a change's row can do; nil where it is not offered.
struct GitChangeCommands {
    var viewDiff: () -> Void
    var openInEditor: (() -> Void)?
    var stage: (() -> Void)?
    var unstage: (() -> Void)?
    var discard: (() -> Void)?
    var vsCode: OpenIn.Item?
}

/// A changed file: its status letter, its name and its folder in secondary text. A click shows its
/// diff; on hover, its buttons.
private struct GitChangeRow: View {
    let change: GitChange
    let list: GitChangeList
    let depth: Int
    let busy: Bool
    let commands: GitChangeCommands
    @State private var hovered = false
    @Environment(\.interfaceScale) private var scale
    @Environment(\.surface) private var surface

    static let expanded = "Expanded"
    static let collapsed = "Collapsed"
    static let fold = "Fold"
    static let unfold = "Unfold"
    static let viewDiffTitle = "View Diff"
    static let openTitle = "Open in Terminal Editor"
    static let stageTitle = "Stage"
    static let unstageTitle = "Unstage"
    static let discardTitle = "Discard Changes"
    static let stageSymbol = "plus"
    static let unstageSymbol = "minus"
    static let discardSymbol = "arrow.uturn.backward"
    static let openSymbol = "doc.text"
    private static let letterWidth: CGFloat = 12

    private var name: String { (change.path as NSString).lastPathComponent }
    private var folder: String { (change.path as NSString).deletingLastPathComponent }

    static func word(_ letter: GitChange.Letter) -> String {
        switch letter {
        case .modified: "modified"
        case .added: "added"
        case .deleted: "deleted"
        case .renamed: "renamed"
        case .copied: "copied"
        case .untracked: "untracked"
        case .typeChanged: "type changed"
        case .conflicted: "conflicted"
        }
    }

    private var letterInk: Color {
        if surface.isOnAccent { return surface.ink }
        switch change.letter {
        case .added, .untracked: return Palette.diffAdded
        case .deleted: return Palette.diffRemoved
        case .conflicted: return Palette.amber
        default: return surface.secondaryInk
        }
    }

    var body: some View {
        HStack(spacing: scale(Space.snug)) {
            Text(change.letter.rawValue).font(Typography.monoCode).foregroundStyle(letterInk)
                .frame(width: scale(Self.letterWidth))
            RowTitle(name)
            if !folder.isEmpty {
                Text(folder).font(Typography.help).foregroundStyle(surface.secondaryInk)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: scale(Space.tight))
            if hovered { buttons }
        }
        .frame(height: scale(Size.menuRow))
        .padding(.leading, GitTitleRow.contentInset(depth: depth, scale))
        .padding(.trailing, SidebarRowLayout.trailingInset(scale))
        .modifier(RowPill(selected: false))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: commands.viewDiff)
        .help(change.originalPath.map { "\($0) → \(change.path)" } ?? change.path)
        .modifier(GitChangeAccessibility(label: label, commands: commands))
        .contextMenu { menu }
    }

    private var label: String {
        ([name, Self.word(change.letter)] + (folder.isEmpty ? [] : [folder])).joined(separator: ", ")
    }

    @ViewBuilder private var buttons: some View {
        if let open = commands.openInEditor { GitIconButton(title: Self.openTitle, symbol: Self.openSymbol, action: open) }
        if let discard = commands.discard {
            GitIconButton(title: Self.discardTitle, symbol: Self.discardSymbol, action: discard).disabled(busy)
        }
        if let stage = commands.stage { GitIconButton(title: Self.stageTitle, symbol: Self.stageSymbol, action: stage).disabled(busy) }
        if let unstage = commands.unstage {
            GitIconButton(title: Self.unstageTitle, symbol: Self.unstageSymbol, action: unstage).disabled(busy)
        }
    }

    @ViewBuilder private var menu: some View {
        if let stage = commands.stage { Button(Self.stageTitle, action: stage).disabled(busy) }
        if let unstage = commands.unstage { Button(Self.unstageTitle, action: unstage).disabled(busy) }
        if let discard = commands.discard { Button(Self.discardTitle, action: discard).disabled(busy) }
        Divider()
        Button(Self.viewDiffTitle, action: commands.viewDiff)
        if let open = commands.openInEditor { Button(Self.openTitle, action: open) }
        if let item = commands.vsCode {
            Divider()
            Button(item.title) { OpenIn.open(item) }
        }
    }
}

/// VoiceOver: “app.ts, modified, src”; the default action shows the diff, and each of the row's
/// commands is an action of its own.
private struct GitChangeAccessibility: ViewModifier {
    let label: String
    let commands: GitChangeCommands

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { commands.viewDiff() }
            .accessibilityAction(named: Text(GitChangeRow.viewDiffTitle), commands.viewDiff)
            .modifier(OptionalAction(title: GitChangeRow.openTitle, run: commands.openInEditor))
            .modifier(OptionalAction(title: GitChangeRow.stageTitle, run: commands.stage))
            .modifier(OptionalAction(title: GitChangeRow.unstageTitle, run: commands.unstage))
            .modifier(OptionalAction(title: GitChangeRow.discardTitle, run: commands.discard))
    }
}

private struct OptionalAction: ViewModifier {
    let title: String
    let run: (() -> Void)?

    func body(content: Content) -> some View {
        if let run { content.accessibilityAction(named: Text(title), run) } else { content }
    }
}

/// A small borderless symbol button, named by its help and for VoiceOver.
private struct GitIconButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @Environment(\.interfaceScale) private var scale
    @Environment(\.surface) private var surface

    var body: some View {
        Button(action: action) {
            Icon(.symbol(symbol), size: scale(Size.trailingGlyph), tint: surface.secondaryInk)
                .frame(width: scale(Size.slot), height: scale(Size.slot))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// The app's one Git panel model, made the first time the panel is shown in any window: until then
/// no repository is read or watched. Every window's panel draws it; each opens diffs in its own window.
@MainActor
public final class GitHolder {
    private let make: @MainActor () -> GitModel
    /// The model, once made; nil until then. Reading it makes nothing.
    private(set) var made: GitModel?

    public init(_ make: @escaping @MainActor () -> GitModel) { self.make = make }

    /// The model, made now if it has not been.
    var model: GitModel {
        if let made { return made }
        let model = make()
        made = model
        return model
    }
}
