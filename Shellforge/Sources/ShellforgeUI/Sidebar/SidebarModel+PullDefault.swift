// Ported from AiTerm (app/Sources/AiTerm/ProjectActions.swift: pullDefault, changeDefaultBranch),
// GPLv3, Laurens D'Hondt.
import Foundation
import ShellforgeCore

/// "Pull main" in a hosted project's menu: its default branch brought to origin's, fast-forward
/// only. AiTerm says the outcome in a toast; Shellforge has none, so it is the sidebar's notice,
/// which clears itself, and a refusal is the error banner. AiTerm's Rebase offer after a diverged
/// pull needs a banner button, which Shellforge has not: the refusal says what diverged.
extension SidebarModel {
    /// AiTerm offers it for a project on GitLab or GitHub only.
    public nonisolated static func offersPull(_ provider: Provider) -> Bool { provider == .gitlab || provider == .github }
    public nonisolated static func pullTitle(branch: String) -> String { "Pull \(branch)" }

    /// The branch the menu names: as last read with the provider, else the usual one.
    public func defaultBranch(of projectId: UUID) -> String {
        defaultBranches[projectId] ?? Repository.fallbackDefaultBranch
    }

    public func isPulling(_ projectId: UUID) -> Bool { removalBoard.pulling.contains(projectId) }

    /// True when a pull ran; false when one was already running for the project, in any window,
    /// or it is gone. The branch is read again first: origin's HEAD may have moved since the menu
    /// was drawn; a branch git cannot name is not guessed, since a guess would move the wrong one.
    @discardableResult
    public func pullDefault(project id: UUID) async -> Bool {
        guard let project = project(id), !removalBoard.pulling.contains(id) else { return false }
        removalBoard.pulling.insert(id)
        defer { removalBoard.pulling.remove(id) }
        let (path, launcher) = (project.path, self.launcher)
        let result = await BackgroundWork.run { () -> (String?, Result<DefaultBranchPull, Error>) in
            let branch: String
            do { branch = try Repository.detectDefaultBranch(of: path, launcher: launcher) } catch { return (nil, .failure(error)) }
            return (branch, Result { try GitRepository(path, launcher: launcher).pullDefaultBranch(branch) })
        }
        // Nothing is said for a project removed while git ran.
        guard self.project(id) != nil else { return true }
        if let branch = result.0, defaultBranches[id] != branch { defaultBranches[id] = branch }
        switch result.1 {
        case .success(let outcome):
            // Its own earlier failure goes; another action's error stays.
            if let said = pullErrors.removeValue(forKey: id), lastError == said { lastError = nil }
            show(notice: outcome.summary)
        case .failure(let error):
            let said = "Couldn’t pull \(result.0 ?? "the default branch"). " + Self.reason(of: error)
            pullErrors[id] = said
            lastError = said
        }
        return true
    }

    /// Said until `noticeLifetime` passes, unless a newer notice replaced it.
    func show(notice text: String) {
        notice = text
        noticeGeneration += 1
        let (lifetime, generation) = (noticeLifetime, noticeGeneration)
        Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            guard let self, self.noticeGeneration == generation else { return }
            self.notice = nil
        }
    }
}
