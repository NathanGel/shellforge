import AppKit
import ShellforgeCore

/// The feedback form's state: what is typed, whether a send is under way, and how it ended.
/// `finished` is reported once, however the sheet closes.
@MainActor public final class FeedbackFormModel: ObservableObject {
    public enum Phase: Equatable {
        case editing, sending, posted(Int), failed(FeedbackFailure)
    }

    @Published public var good = ""
    @Published public var bad = ""
    /// 1 to 5, or nil: anything else is dropped.
    @Published public var rating: Int? {
        didSet { if let rating, !(1...5).contains(rating) { self.rating = nil } }
    }
    @Published public private(set) var phase = Phase.editing
    @Published public private(set) var note: String?

    /// False when there is no relay: Send then opens GitHub.
    public let viaRelay: Bool
    public let versions: AppVersions
    /// Set when feedback went out less than a day ago: the relay's Send is refused until then.
    /// GitHub's own form stays open, since it posts under the person's own account.
    public let blockedUntil: Date?

    private let sender: (@Sendable (FeedbackSubmission) async throws -> Int)?
    private let open: @MainActor (URL) -> Void
    private let copy: @MainActor (String) -> Void
    private let report: @MainActor (Bool) -> Void
    private var reported = false
    private var task: Task<Void, Never>?
    /// The latest send, kept after a cancel so `settled()` can wait for its late answer.
    private var lastTask: Task<Void, Never>?
    /// True once the GitHub form is open with the text on the clipboard and the sheet stays up for the note.
    @Published public private(set) var handedOff = false
    /// Tells a send's answer whether it is still wanted.
    private var attempt = 0

    public init(versions: AppVersions,
                send: (@Sendable (FeedbackSubmission) async throws -> Int)?,
                blockedUntil: Date? = nil,
                open: @escaping @MainActor (URL) -> Void,
                copy: @escaping @MainActor (String) -> Void,
                finished: @escaping @MainActor (_ sent: Bool) -> Void) {
        self.versions = versions
        self.sender = send
        self.viaRelay = send != nil
        self.blockedUntil = viaRelay ? blockedUntil : nil
        self.open = open
        self.copy = copy
        self.report = finished
    }

    /// The form as it opens for real. Opening it counts as the ask, once, whether the banner or the
    /// Help menu opened it; a form that never opens (the panel is busy) spends nothing.
    public static func live(prompt: FeedbackPrompt, dismiss: @escaping @MainActor () -> Void) -> FeedbackFormModel {
        prompt.beginFeedback()
        let versions = AppVersions.current
        let client = FeedbackRelay.client(versions: versions)
        return FeedbackFormModel(
            versions: versions,
            send: client.map { client in { @Sendable submission in try await client.send(submission) } },
            blockedUntil: prompt.sendBlockedUntil,
            open: { NSWorkspace.shared.open($0) },
            copy: { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            },
            finished: { sent in
                prompt.finished(sent: sent)
                dismiss()
            })
    }

    private var submission: FeedbackSubmission {
        FeedbackSubmission(versions: versions, good: good, bad: bad, rating: rating)
    }

    public var canSend: Bool {
        guard blockedUntil == nil, phase == .editing || isFailed else { return false }
        return submission.hasText
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    public func send() {
        guard canSend else { return }
        guard let sender else {
            openInGitHub()
            // A cut link put the text on the clipboard: stay up until the person has seen the note.
            if note == FeedbackFormPresentation.onClipboard { handedOff = true } else { finish(sent: false) }
            return
        }
        let submission = submission
        attempt += 1
        let mine = attempt
        note = nil
        phase = .sending
        task = Task { [weak self] in
            let result: Result<Int, Error>
            do { result = .success(try await sender(submission)) } catch { result = .failure(error) }
            self?.answered(result, attempt: mine)
        }
        lastTask = task
    }

    private func answered(_ result: Result<Int, Error>, attempt mine: Int) {
        // A cancelled or closed send's answer is not wanted, whatever it says.
        guard mine == attempt, phase == .sending, !reported else { return }
        switch result {
        case .success(let number): phase = .posted(number)
        case .failure(let error): phase = .failed(error as? FeedbackFailure ?? .other)
        }
    }

    /// Cancels a send under way, or closes the form. Either way it is not “sent”, unless it already was.
    public func cancel() {
        if case .posted = phase { finish(sent: true); return }
        attempt += 1
        task?.cancel()
        task = nil
        if phase == .sending { phase = .editing }
        finish(sent: false)
    }

    public func done() {
        if case .posted = phase { finish(sent: true) } else { cancel() }
    }

    /// Opens the GitHub form. Text too long for the link goes to the clipboard as well.
    public func openInGitHub() {
        let submission = submission
        let (url, cut) = FeedbackLink.form(submission)
        open(url)
        if cut {
            copy(submission.plainText)
            note = FeedbackFormPresentation.onClipboard
        }
    }

    public func copyAll() {
        copy(submission.plainText)
        note = FeedbackFormPresentation.copied
    }

    private func finish(sent: Bool) {
        guard !reported else { return }
        reported = true
        report(sent)
    }

    /// Returns once any send's answer has been taken in.
    func settled() async { await lastTask?.value }
}

public enum FeedbackFormPresentation {
    static let purpose = "Shellforge gets the features and fixes people ask for. Nobody sees what you need unless you say so here."
    static let goodLabel = "What’s working well?"
    static let missingLabel = "What’s missing, or gets in your way?"
    static func sentRecently(_ until: Date) -> String {
        "You already sent feedback in the last day. You can send more from \(until.formatted(date: .abbreviated, time: .shortened)), or open it in GitHub now."
    }
    static let relayWarning = "This becomes a public issue on github.com/NathanGel/shellforge, posted anonymously. Anyone can read it, and you can’t edit or delete it yourself. Don’t include names, client details, commands, output, paths or passwords."
    /// The form's main button: Send through the relay, else the GitHub link.
    static func primaryTitle(viaRelay: Bool) -> String { viaRelay ? "Send" : "Open in GitHub" }
    public static let githubWarning = "Opens GitHub in your browser. You need a GitHub account, and the issue is posted publicly under your name. Don’t include names, client details, commands, output, paths or passwords."
    static func alsoSent(_ versions: AppVersions) -> String { "Also sent: Shellforge \(versions.version), macOS \(versions.macOS)." }
    static let ipNote = "Your IP address is used only for a one-minute rate limit and is not kept."
    static let sending = "Sending…"
    static func thanks(_ n: Int) -> String { "Thanks — posted as issue #\(n)." }
    static let copied = "Copied."
    static let onClipboard = "Your feedback is on the clipboard."
}
