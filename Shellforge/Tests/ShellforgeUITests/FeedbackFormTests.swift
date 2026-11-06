import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI

/// A relay stand-in the test answers by hand: `send` suspends until `resume`, so no test waits on a clock.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int, Error>?
    private var cancelledFlag = false
    private let startedStream: AsyncStream<Void>
    private let startedSignal: AsyncStream<Void>.Continuation

    init() { (startedStream, startedSignal) = AsyncStream.makeStream() }

    var wasCancelled: Bool { lock.withLock { cancelledFlag } }

    func send(_ submission: FeedbackSubmission) async throws -> Int {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int, Error>) in
                lock.withLock { continuation = c }
                startedSignal.yield()
            }
        } onCancel: {
            lock.withLock { cancelledFlag = true }
        }
    }

    /// Returns once `send` is suspended.
    func started() async { for await _ in startedStream { return } }

    func resume(_ result: Result<Int, Error>) {
        let c = lock.withLock { () -> CheckedContinuation<Int, Error>? in defer { continuation = nil }; return continuation }
        c?.resume(with: result)
    }
}

@MainActor private final class Recorder {
    var finished: [Bool] = []
    var opened: [URL] = []
    var copied: [String] = []
}

@MainActor @Suite struct FeedbackFormTests {
    private static let versions = AppVersions(version: "0.8.0", macOS: "26.1.0")

    private func make(_ gate: Gate?, _ r: Recorder, relay: Bool = true) -> FeedbackFormModel {
        let gate = gate ?? Gate()
        let send: (@Sendable (FeedbackSubmission) async throws -> Int)? = relay ? { @Sendable s in try await gate.send(s) } : nil
        return FeedbackFormModel(versions: Self.versions, send: send,
                          open: { r.opened.append($0) }, copy: { r.copied.append($0) },
                          finished: { r.finished.append($0) })
    }

    @Test func copyIsTheSpecs() {
        typealias P = FeedbackFormPresentation
        #expect(P.relayWarning == "This becomes a public issue on github.com/NathanGel/shellforge, posted anonymously. Anyone can read it, and you can’t edit or delete it yourself. Don’t include names, client details, commands, output, paths or passwords.")
        #expect(P.githubWarning == "Opens GitHub in your browser. You need a GitHub account, and the issue is posted publicly under your name. Don’t include names, client details, commands, output, paths or passwords.")
        #expect(P.alsoSent(Self.versions) == "Also sent: Shellforge 0.8.0, macOS 26.1.0.")
        #expect(P.ipNote == "Your IP address is used only for a one-minute rate limit and is not kept.")
        #expect(P.thanks(12) == "Thanks — posted as issue #12.")
        #expect(P.sending == "Sending…")
        #expect(P.copied == "Copied.")
        #expect(P.onClipboard == "Your feedback is on the clipboard.")
    }

    @Test func sendNeedsText() {
        let model = make(Gate(), Recorder())
        #expect(!model.canSend)
        model.rating = 4
        #expect(!model.canSend)
        model.good = " \n "
        #expect(!model.canSend)
        model.bad = "slow"
        #expect(model.canSend)
    }

    @Test func successFinishesSent() async {
        let gate = Gate(), r = Recorder(), model = make(gate, r)
        model.good = "nice"
        model.send()
        #expect(model.phase == .sending)
        await gate.started()
        gate.resume(.success(12))
        await model.settled()
        #expect(model.phase == .posted(12))
        #expect(r.finished.isEmpty)
        model.done()
        #expect(r.finished == [true])
        #expect(FeedbackLink.issue(12).absoluteString == "https://github.com/NathanGel/shellforge/issues/12")
    }

    @Test func failureKeepsTheText() async {
        let gate = Gate(), r = Recorder(), model = make(gate, r)
        model.good = "nice"; model.bad = "slow"
        model.send()
        await gate.started()
        gate.resume(.failure(FeedbackFailure.daily))
        await model.settled()
        #expect(model.phase == .failed(.daily))
        #expect(model.good == "nice" && model.bad == "slow")
        #expect(r.copied.isEmpty)
        #expect(r.finished.isEmpty)
    }

    @Test func cancelWhileSendingIsNotNow() async {
        let gate = Gate(), r = Recorder(), model = make(gate, r)
        model.bad = "slow"
        model.send()
        await gate.started()
        model.cancel()
        #expect(gate.wasCancelled)
        #expect(r.finished == [false])
        gate.resume(.success(12))
        await model.settled()
        #expect(r.finished == [false])
        #expect(model.phase == .editing)
    }

    @Test func closeAfterFailureIsNotNow() async {
        let gate = Gate(), r = Recorder(), model = make(gate, r)
        model.bad = "slow"
        model.send()
        await gate.started()
        gate.resume(.failure(FeedbackFailure.off))
        await model.settled()
        model.cancel()
        #expect(r.finished == [false])
        model.cancel()
        #expect(r.finished == [false])
    }

    @Test func copyAllCopiesPlainText() {
        let r = Recorder(), model = make(Gate(), r)
        model.good = "nice"; model.rating = 5
        model.copyAll()
        #expect(r.copied == [FeedbackSubmission(versions: Self.versions, good: "nice", bad: "", rating: 5).plainText])
        #expect(model.note == "Copied.")
    }

    @Test func openInGitHubCopiesWhenCut() {
        let r = Recorder(), model = make(Gate(), r)
        model.bad = String(repeating: "é", count: 3000)
        model.openInGitHub()
        #expect(r.opened.count == 1)
        #expect(r.opened[0].absoluteString.utf8.count <= 7000)
        #expect(r.copied == [FeedbackSubmission(versions: Self.versions, good: "", bad: model.bad, rating: nil).plainText])
        #expect(model.note == "Your feedback is on the clipboard.")

        let r2 = Recorder(), short = make(Gate(), r2)
        short.bad = "slow"
        short.openInGitHub()
        #expect(r2.opened.count == 1)
        #expect(r2.copied.isEmpty)
        #expect(short.note == nil)
    }

    @Test func ratingOutsideOneToFiveIsNil() {
        let model = make(Gate(), Recorder())
        model.rating = 3
        #expect(model.rating == 3)
        model.rating = 0
        #expect(model.rating == nil)
        model.rating = 6
        #expect(model.rating == nil)
    }

    @Test func secondSendAfterFailureIsPosted() async {
        let gate = Gate(), r = Recorder(), model = make(gate, r)
        model.bad = "slow"
        model.send()
        await gate.started()
        gate.resume(.failure(FeedbackFailure.tooMany))
        await model.settled()
        #expect(model.phase == .failed(.tooMany))
        model.send()
        #expect(model.phase == .sending)
        await gate.started()
        gate.resume(.success(7))
        await model.settled()
        #expect(model.phase == .posted(7))
    }

    @Test func cancelAfterPostedIsSent() async {
        let gate = Gate(), r = Recorder(), model = make(gate, r)
        model.bad = "slow"
        model.send()
        await gate.started()
        gate.resume(.success(3))
        await model.settled()
        model.cancel()
        #expect(r.finished == [true])
    }

    @Test func noRelayCutSendStaysUpForTheNote() {
        let r = Recorder(), model = make(nil, r, relay: false)
        model.bad = String(repeating: "é", count: 3000)
        model.send()
        #expect(r.opened.count == 1)
        #expect(model.note == "Your feedback is on the clipboard.")
        #expect(r.finished.isEmpty)
        model.done()
        #expect(r.finished == [false])
    }

    @Test func noRelaySendOpensGitHub() {
        let r = Recorder(), model = make(nil, r, relay: false)
        #expect(!model.viaRelay)
        model.bad = "slow"
        model.send()
        #expect(r.opened.count == 1)
        #expect(r.finished == [false])
    }
}
