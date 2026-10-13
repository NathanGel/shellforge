import Foundation

/// Many signals in one main run-loop turn, one `fire` at its end. iTerm2 posts a notification per
/// tab-title change — several a second while an agent works — and each would rebuild the sidebar
/// and resend the session list; a burst is one change.
@MainActor
public final class ChangeCoalescer {
    public typealias Work = @MainActor () -> Void
    private let schedule: (@escaping Work) -> Void
    private let fire: Work
    private var pending = false

    /// `schedule` runs its work later on the main actor: the next run-loop turn unless a test
    /// drives it by hand.
    public init(schedule: @escaping (@escaping Work) -> Void = ChangeCoalescer.nextTurn, fire: @escaping Work) {
        self.schedule = schedule
        self.fire = fire
    }

    public static let nextTurn: (@escaping Work) -> Void = { work in
        DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
    }

    public func signal() {
        guard !pending else { return }
        pending = true
        schedule { [weak self] in
            guard let self else { return }
            pending = false
            fire()
        }
    }
}
