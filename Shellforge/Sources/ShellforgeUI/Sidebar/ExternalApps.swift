// Ported from AiTerm (app/Sources/AiTerm/ExternalApps.swift), GPLv3, Laurens D'Hondt.
import AppKit
import ShellforgeCore
import ShellforgeDesign
import SwiftUI

/// The two things a row can hand a folder to. VS Code is looked up once by bundle id, so its badge
/// and menu items can simply be absent when it is not installed.
public enum OpenIn {
    public enum App: Equatable, Sendable { case finder, vsCode }

    public struct Item: Equatable, Sendable {
        public let title: String
        public let app: App
        public let folder: String
    }

    /// The rows that hand a folder over.
    public enum Row {
        case project(Project), task(TaskItem), terminal(TerminalItem, project: Project)
    }

    /// A project its checkout, a task or review its worktree, a terminal its project's folder.
    public static func folder(of row: Row) -> String {
        switch row {
        case .project(let project): project.path
        case .task(let task): task.worktreePath
        case .terminal(_, let project): project.path
        }
    }

    /// None for a row with no folder yet: Finder would open at /.
    public static func items(folder: String, vsCodeInstalled: Bool) -> [Item] {
        guard !folder.isEmpty else { return [] }
        return [Item(title: "Open in Finder", app: .finder, folder: folder)]
            + (vsCodeInstalled ? [Item(title: "Open in VS Code", app: .vsCode, folder: folder)] : [])
    }

    static let vsCodeBundleId = "com.microsoft.VSCode"
    /// Looked up once, as AiTerm does: an install while Shellforge runs shows at the next launch.
    static let vsCode: URL? = NSWorkspace.shared.urlForApplication(withBundleIdentifier: vsCodeBundleId)
    static var vsCodeInstalled: Bool { vsCode != nil }

    @MainActor
    static func open(_ item: Item) {
        let url = URL(fileURLWithPath: item.folder, isDirectory: true)
        switch item.app {
        case .finder: NSWorkspace.shared.open(url)
        case .vsCode:
            guard let app = vsCode else { return }
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

/// A row's Open in Finder and Open in VS Code, for its context menu.
struct OpenInMenuItems: View {
    let folder: String

    var body: some View {
        ForEach(OpenIn.items(folder: folder, vsCodeInstalled: OpenIn.vsCodeInstalled), id: \.title) { item in
            Button(item.title) { OpenIn.open(item) }
        }
    }
}

/// The VS Code badge on a task or terminal row, when it is installed. A task's carries AiTerm's
/// `+n −m`, its worktree's lines against its base, named in the help rather than the badge.
struct VSCodeBadge: View {
    let folder: String
    var diff: DiffStat? = nil
    var base = ""

    var body: some View {
        if OpenIn.vsCodeInstalled {
            Badge(nil, icon: .brand(Palette.vscode), help: Self.help(diff: diff, base: base),
                  diff: Self.shown(diff, base: base).map { Badge.Diff(added: $0.added, removed: $0.removed) }, style: .quiet,
                  action: { OpenIn.open(OpenIn.Item(title: "Open in VS Code", app: .vsCode, folder: folder)) })
        }
    }

    /// A diff worth drawing: a base to measure against, and something changed.
    private static func shown(_ diff: DiffStat?, base: String) -> DiffStat? {
        guard !base.isEmpty, let diff, !diff.isEmpty else { return nil }
        return diff
    }

    /// AiTerm's `BaseDiff.help`: "Open in VS Code — 12 added, 3 removed against main".
    static func help(diff: DiffStat?, base: String) -> String {
        guard let stat = shown(diff, base: base) else { return "Open in VS Code" }
        let counts = (stat.added > 0 ? ["\(stat.added) added"] : []) + (stat.removed > 0 ? ["\(stat.removed) removed"] : [])
        return "Open in VS Code \u{2014} " + counts.joined(separator: ", ") + " against " + base
    }
}
