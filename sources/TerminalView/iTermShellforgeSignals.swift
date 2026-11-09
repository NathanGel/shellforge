//
//  iTermShellforgeSignals.swift
//  Shellforge
//
//  What each session's terminal says about the agent in it, for an agent with no hooks of its own:
//  how much it has printed apart from echoing the user's typing, and how often it has asked for
//  attention (a bell, OSC 9, OSC 777 notify). PTYSession counts into it; the helper's reports read
//  it (`SessionReport.reading`). It also types a task's first prompt into an agent that takes it
//  typed in, once the agent has settled (`TypedPromptDriver`).
//

import AppKit
import ShellforgeCore

@objc(iTermShellforgeSignals)
@MainActor
final class iTermShellforgeSignals: NSObject {
    /// By session guid. An entry is made on a session's first output or attention, and goes with it.
    private static var counters: [String: TerminalSignals] = [:]
    /// The typed prompts on their way, by session guid.
    private static var typists: [String: PromptTypist] = [:]

    /// Called for each batch of output PTYSession executes: one dictionary update, nothing allocated
    /// once the session has its entry. Output within `TerminalSignals.echoWindow` of a keypress is
    /// the terminal echoing it and is not counted.
    @objc static func output(_ guid: String, bytes: Int, sinceInput: TimeInterval) {
        counters[guid, default: TerminalSignals()].output(bytes, sinceInput: sinceInput)
    }

    /// The session rang its bell or posted a notification.
    @objc static func attention(_ guid: String) {
        DLog("Shellforge: a session asked for attention")
        counters[guid, default: TerminalSignals()].attentionRequested()
    }

    /// The session is closing: its counters, and a prompt still waiting to be typed, go with it.
    @objc static func ended(_ guid: String) {
        counters[guid] = nil
        if let typist = typists.removeValue(forKey: guid) {
            DLog("Shellforge: a tab closed before its typed prompt went")
            typist.stop()
        }
    }

    static func signals(_ guid: String) -> TerminalSignals? { counters[guid] }

    /// Types `launch`'s prompt into `session` once its agent has settled, at most once. A timer reads
    /// the session every quarter second until the prompt is typed or given up, or the session ends.
    /// `exited` is told when the agent ran and ended before the prompt could go.
    static func type(_ launch: AgentLaunch, into session: PTYSession, exited: @escaping @MainActor () -> Void) {
        guard let driver = TypedPromptDriver(launch: launch, armedAt: Date()) else { return }
        let guid: String = session.guid
        DLog("Shellforge: waiting to type a task's first prompt")
        typists.removeValue(forKey: guid)?.stop()
        let typist = PromptTypist(driver: driver, session: session, exited: exited) { finished(guid) }
        typists[guid] = typist
        typist.start()
    }

    private static func finished(_ guid: String) {
        typists.removeValue(forKey: guid)?.stop()
    }
}

/// One typed prompt's timer. It holds its session weakly, and stops on any outcome.
@MainActor
private final class PromptTypist {
    static let interval: TimeInterval = 0.25

    private var driver: TypedPromptDriver
    private weak var session: PTYSession?
    private let exited: @MainActor () -> Void
    private let done: @MainActor () -> Void
    private var timer: Timer?
    private var finished = false

    init(driver: TypedPromptDriver, session: PTYSession, exited: @escaping @MainActor () -> Void,
         done: @escaping @MainActor () -> Void) {
        self.driver = driver
        self.session = session
        self.exited = exited
        self.done = done
    }

    /// In the common modes: `TypingReadiness` needs a sample at least every 0.5 s, menu open or not.
    func start() {
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let session, !session.exited else {
            DLog("Shellforge: a typed prompt's session is gone")
            done()
            return
        }
        let step = driver.observe(commandLine: Self.commandLine(of: session),
                                  outputBytes: iTermShellforgeSignals.signals(session.guid)?.outputBytes ?? 0,
                                  now: Date())
        switch step {
        case .wait:
            return
        case .type:
            stop()
            confirmThenType(session)
            return
        case .abandon(let agentExited):
            DLog("Shellforge: gave up typing a task's first prompt; the agent exited: \(agentExited)")
            if agentExited { exited() }
        case .finished:
            DLog("Shellforge: a typed prompt was already handled")
        }
        done()
    }

    private static func commandLine(of session: PTYSession) -> String? {
        session.genericScope.value(forVariableName: SessionReport.Variable.commandLine) as? String
    }

    /// How long the fresh read may take before the prompt is given up: a remote tab's provider may
    /// never answer.
    static let confirmLimit: TimeInterval = 2

    /// The poll behind `commandLine` can trail the tab by half a second, or five while the app is
    /// inactive, so the agent may have ended since: the process cache is read again now, and the
    /// paste goes only if the agent is still in the foreground (`TypedPromptDriver.confirm`).
    private func confirmThenType(_ session: PTYSession) {
        guard let provider = session.processInfoProvider else {
            DLog("Shellforge: no process information to confirm a typed prompt against; not typing it")
            done()
            return
        }
        let limit = Timer(timeInterval: Self.confirmLimit, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                DLog("Shellforge: the process cache didn't answer in time; not typing a task's first prompt")
                self?.finish()
            }
        }
        RunLoop.main.add(limit, forMode: .common)
        timer = limit
        provider.requestImmediateUpdate { [weak self] in
            // Hopped explicitly: a remote tab's provider may not answer on the main thread.
            Task { @MainActor in self?.confirmed() }
        }
    }

    /// Ends this typist once: a late answer after the limit, or the limit after an answer, does nothing.
    private func finish() {
        guard !finished else { return }
        finished = true
        stop()
        done()
    }

    private func confirmed() {
        guard !finished else { return }
        guard let session, !session.exited else {
            DLog("Shellforge: a typed prompt's session ended before it was confirmed")
            finish()
            return
        }
        // Only a cache that knows this tab's task refreshes `commandLine`; without it the reading
        // would be the stale one this check is for.
        guard (session.shell as AnyObject as? SessionProcessInfoProvider)?.cachedProcessInfoIfAvailable() != nil else {
            DLog("Shellforge: the process cache has nothing for this tab; not typing a task's first prompt")
            finish()
            return
        }
        session.refreshForegroundJobFromCacheIfAvailable()
        switch driver.confirm(commandLine: Self.commandLine(of: session)) {
        case .type(let paste):
            DLog("Shellforge: typing a task's first prompt")
            session.writeTaskNoBroadcast(paste)
        case .abandon(let agentExited):
            DLog("Shellforge: the agent left the foreground just before its typed prompt; the agent exited: \(agentExited)")
            if agentExited { exited() }
        case .wait, .finished:
            break
        }
        finish()
    }
}
