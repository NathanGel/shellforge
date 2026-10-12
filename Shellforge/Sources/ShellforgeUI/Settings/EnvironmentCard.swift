import ShellforgeCore
import ShellforgeDesign
import SwiftUI

/// The environment Shellforge starts things in, for Settings › Core: read off the main actor — the
/// first read runs a login shell — and read again by Reload, one read at a time.
@MainActor
public final class EnvironmentModel: ObservableObject {
    @Published public private(set) var report: EnvironmentReport?
    @Published public private(set) var reading = false
    /// After a Reload: the app refreshes every sidebar's warning.
    public var onReloaded: (@MainActor () -> Void)?

    private let launcher: CommandLauncher
    private let agents: [AgentDefinition]

    public init(launcher: CommandLauncher, agents: [AgentDefinition]) {
        self.launcher = launcher
        self.agents = agents
    }

    /// The report from the environment as read, reading it first if it has not been.
    public func load() async {
        let launcher = self.launcher, agents = self.agents
        report = await BackgroundWork.run { EnvironmentReport.make(launcher: launcher, agents: agents) }
    }

    /// Reads the environment again; a press while it reads does nothing.
    public func reload() async {
        guard !reading else { return }
        reading = true
        let launcher = self.launcher, agents = self.agents
        report = await BackgroundWork.run { () -> EnvironmentReport in
            launcher.reload()
            return EnvironmentReport.make(launcher: launcher, agents: agents)
        }
        reading = false
        onReloaded?()
    }
}

/// Settings › Core › Environment (PRD E8): the shell, when it was read, the PATH's folders, and where
/// each tool was found, with Reload.
struct EnvironmentCard: View {
    @ObservedObject var model: EnvironmentModel

    /// The card's status line: where the environment came from, or why a fallback is used.
    static func status(_ report: EnvironmentReport?, now: Date) -> SettingsStatus {
        guard let report else { return SettingsStatus(.idle, "Reading your login shell…") }
        if let reason = report.fallbackReason { return SettingsStatus(.attention, "A fallback PATH: \(reason)") }
        let when = report.readAt.map { " " + ago($0, now: now) } ?? ""
        return SettingsStatus(.ready, "Read from \(report.shell ?? "your login shell")\(when)")
    }

    /// "just now", "1 minute ago", "3 hours ago" — in the app's own words, whatever the locale.
    static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: let m = seconds / 60; return m == 1 ? "1 minute ago" : "\(m) minutes ago"
        default: let h = seconds / 3600; return h == 1 ? "1 hour ago" : "\(h) hours ago"
        }
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            SettingsCard(title: "Environment", status: Self.status(model.report, now: context.date)) {
                SymbolMark(symbol: "terminal", size: Size.control, style: .paper)
            } chips: {
                EmptyView()
            } actions: {
                if model.reading { ProgressView().controlSize(.small) }
                Button("Reload") { Task { await model.reload() } }.disabled(model.reading)
            } content: {
                if let report = model.report { details(report) }
            }
        }
        .task { if model.report == nil { await model.load() } }
    }

    private func details(_ report: EnvironmentReport) -> some View {
        VStack(alignment: .leading, spacing: Space.block) {
            FormField("Tools") {
                VStack(alignment: .leading, spacing: Space.tight) {
                    ForEach(report.tools, id: \.name) { tool in
                        HStack(spacing: Space.snug) {
                            Text(tool.name).font(Typography.monoCode).foregroundStyle(Palette.text)
                            Text(tool.path ?? "not found").font(Typography.monoCode)
                                .foregroundStyle(tool.path == nil ? Palette.amber : Palette.muted)
                                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        }
                    }
                }
            }
            FormField("PATH") {
                VStack(alignment: .leading, spacing: Space.tight) {
                    ForEach(Array(report.path.enumerated()), id: \.offset) { _, folder in
                        Text(folder).font(Typography.monoCode).foregroundStyle(Palette.muted)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                }
            }
        }
    }
}
