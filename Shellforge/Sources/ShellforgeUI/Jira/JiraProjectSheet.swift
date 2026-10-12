// Ported from AiTerm (app/Sources/AiTerm/Views/JiraProjectSheet.swift), GPLv3, Laurens D'Hondt.
import ShellforgeCore
import ShellforgeDesign
import SwiftUI

/// Edits the Jira projects linked to a Shellforge project, opened from the project's context menu
/// or its badge's `+n` menu — adding a project links none, and asks nothing about Jira. An empty
/// list is a valid answer: New Task then searches every Jira project.
///
/// Each linked project is drawn as a `PickedItemField`, the way a picked ticket is, and its ✕
/// unlinks it; the `SearchPicker` below them adds one more. Nothing changes until Save hands the
/// whole list up.
///
/// It searches rather than scrolls: an account can see hundreds of Jira projects, and a popup menu
/// of that length is a list you hunt through rather than one you choose from. `JiraClient.projects()`
/// already pages the whole list in, so the field filters what is in hand — `JiraProjectSearch`,
/// which also leaves out what is linked — and never asks Jira again.
struct JiraProjectSheet: View {
    /// The band's one sentence: what linking changes.
    static let subtitle = "New Task searches for tickets in the Jira projects linked here."

    let projectName: String
    let canSubmit: Bool
    let loadProjects: () async throws -> [JiraProjectRef]
    let submit: ([JiraProjectRef]) -> Void
    let dismiss: @MainActor () -> Void

    // `@State` is a macro in the macOS 26 SDK and its SwiftUIMacros plugin ships only with Xcode;
    // these are the storage and accessors the macro would generate.
    private var _projects = State(initialValue: [JiraProjectRef]())
    private var _linked: State<[JiraProjectRef]>
    private var _loading = State(initialValue: true)
    private var _error = State<String?>(initialValue: nil)
    private var _query = State(initialValue: "")
    private var _open = State(initialValue: false)

    init(projectName: String, linked: [JiraProjectRef], canSubmit: Bool,
         loadProjects: @escaping () async throws -> [JiraProjectRef], submit: @escaping ([JiraProjectRef]) -> Void,
         dismiss: @escaping @MainActor () -> Void) {
        self.projectName = projectName
        self.canSubmit = canSubmit; self.loadProjects = loadProjects; self.submit = submit; self.dismiss = dismiss
        _linked = State(initialValue: linked)
    }

    /// A result row's key column, in the mono code face, so the names after it start on one line.
    /// A project key is a ticket key without its number, so the column is narrower than New Task's.
    private static let keyColumnWidth: CGFloat = 64

    private var projects: [JiraProjectRef] {
        get { _projects.wrappedValue }
        nonmutating set { _projects.wrappedValue = newValue }
    }
    private var linked: [JiraProjectRef] {
        get { _linked.wrappedValue }
        nonmutating set { _linked.wrappedValue = newValue }
    }
    private var loading: Bool {
        get { _loading.wrappedValue }
        nonmutating set { _loading.wrappedValue = newValue }
    }
    private var error: String? {
        get { _error.wrappedValue }
        nonmutating set { _error.wrappedValue = newValue }
    }
    private var query: String {
        get { _query.wrappedValue }
        nonmutating set { _query.wrappedValue = newValue }
    }
    private var open: Bool {
        get { _open.wrappedValue }
        nonmutating set { _open.wrappedValue = newValue }
    }

    private var matches: [JiraProjectRef] { JiraProjectSearch.rank(projects, query: query, excluding: linked) }

    var body: some View {
        SheetLayout(title: "Jira projects for \(projectName)", height: Sheet.height, onBackgroundTap: { open = false }) {
            SheetSubtitle(Self.subtitle)
        } content: {
            FormField("Jira projects") {
                ForEach(linked) { linkedProject($0) }
                // Never handed a selection: a pick joins the list above, and the field stays
                // for the next one.
                SearchPicker(placeholder: "Add a Jira project by key or name",
                             query: _query.projectedValue, open: _open.projectedValue,
                             items: matches, selection: nil,
                             row: projectRow,
                             selected: { _ in EmptyView() },
                             onPick: { linked.append($0) },
                             toggleHelp: { $0 ? "Hide Jira projects" : "Show Jira projects" })
                    // Over the status line after it, as AiTerm's FormField orders its content front to back.
                    .zIndex(1)
                status
            }
        } footer: {
            SheetFooter(primary: "Save", canSubmit: canSubmit, closeList: closeList,
                        cancel: { Task { @MainActor in dismiss() } }, submit: confirm)
        }
        .task { await load() }
    }

    /// ⎋ closes the list while it is open, and only then the sheet.
    private func closeList() -> Bool {
        guard open else { return false }
        open = false
        return true
    }

    /// Hands the list up, then dismisses once the button's own event is over.
    private func confirm() {
        guard canSubmit else { return }
        submit(linked)
        Task { @MainActor in dismiss() }
    }

    private func projectRow(_ project: JiraProjectRef) -> some View {
        PickerResultRow(mark: .brand(Palette.jira), key: project.key, keyWidth: Self.keyColumnWidth,
                        title: project.name, detail: nil)
    }

    private func linkedProject(_ project: JiraProjectRef) -> some View {
        PickedItemField(mark: .brand(Palette.jira), key: project.key, title: project.name,
                        clearHelp: "Unlink \(project.key)") {
            linked.removeAll { $0.id == project.id }
        }
    }

    /// The line under the field: what the sheet is doing, what went wrong, or what the list as it
    /// stands will mean for New Task. A value, so the copy is testable without rendering.
    struct StatusLine: Equatable {
        let text: String
        let tone: HelpText.Tone
    }

    static func statusLine(loading: Bool, error: String?, projects: [JiraProjectRef], linked: [JiraProjectRef]) -> StatusLine? {
        if loading { return StatusLine(text: "Loading Jira projects…", tone: .secondary) }
        if let error { return StatusLine(text: error, tone: .warning) }
        if projects.isEmpty { return StatusLine(text: "No Jira projects are available to this account.", tone: .secondary) }
        if linked.isEmpty { return StatusLine(text: "Leave this empty to show tickets from every Jira project.", tone: .secondary) }
        return StatusLine(text: "New tasks will show tickets from \(linked.keyList).", tone: .secondary)
    }

    @ViewBuilder private var status: some View {
        if let line = Self.statusLine(loading: loading, error: error, projects: projects, linked: linked) {
            if loading {
                HStack(spacing: Space.snug) {
                    ProgressView().controlSize(.small)
                    HelpText(line.text, tone: line.tone)
                }
            } else {
                HelpText(line.text, tone: line.tone)
            }
        }
    }

    private func load() async {
        loading = true
        error = nil
        do {
            let found = try await loadProjects()
            guard !Task.isCancelled else { return }
            projects = found
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
        loading = false
    }
}

#if DEBUG
extension JiraProjectSheet {
    /// The sheet as a load leaves it, with `projects` in hand, and its list open or not: only a
    /// click opens the list. For the tests that host the sheet.
    func seeded(projects: [JiraProjectRef]? = nil, open: Bool = false) -> Self {
        var sheet = self
        if let projects {
            sheet._projects = State(initialValue: projects)
            sheet._loading = State(initialValue: false)
        }
        sheet._open = State(initialValue: open)
        return sheet
    }
}
#endif
