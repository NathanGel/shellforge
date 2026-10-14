// Ported from AiTerm (app/Sources/AiTermCore/Updates/UpdateCheck.swift), GPLv3, Laurens D'Hondt.
import Foundation

public enum UpdateCheckResult: Equatable, Sendable {
    case current(ReleaseVersion), available(Release), failed(UpdateError)
}

public enum UpdateCheck {
    /// A release is offered only when it is newer: a build ahead of the newest release is told it
    /// is current rather than offered a downgrade. Nothing cancels a check (Check for Updates… runs
    /// it to its last alert), so cancellation is no outcome of its own.
    public static func run(source: any ReleaseSource, current: ReleaseVersion) async -> UpdateCheckResult {
        do {
            let release = try await source.latest()
            return release.version > current ? .available(release) : .current(current)
        } catch let error as UpdateError {
            return .failed(error)
        } catch {
            return .failed(.other(error.localizedDescription))
        }
    }
}
