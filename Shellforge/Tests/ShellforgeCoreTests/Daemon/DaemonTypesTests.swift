// Ported from AiTerm (app/Tests/AiTermCoreTests/DaemonTypesTests.swift, its first five tests), GPLv3, Laurens D'Hondt.
import Foundation
import Testing
@testable import ShellforgeCore

@Suite struct DaemonTypesTests {
    @Test func sessionReasoningDecodesWhenPresentAndDefaultsToNilWhenAbsent() throws {
        let withReasoning = #"{"sessionId":"s1","windowId":"w1","tabIndex":0,"taskId":null,"projectId":null,"agent":"pi","model":"openai/model-x","reasoning":"high","state":"working","title":"PI","cwd":"/repo"}"#
        let pi = try JSONDecoder().decode(SessionInfo.self, from: Data(withReasoning.utf8))
        #expect(pi.agent == .pi)
        #expect(pi.reasoning == "high")

        let legacy = #"{"sessionId":"s2","windowId":"w1","tabIndex":1,"taskId":null,"projectId":null,"agent":"codex","model":"gpt-5.6","state":"idle","title":"Codex","cwd":"/repo"}"#
        let codex = try JSONDecoder().decode(SessionInfo.self, from: Data(legacy.utf8))
        #expect(codex.reasoning == nil)
    }

    /// A session carries what its conversation has spent; an older daemon, or a tab whose agent has
    /// not replied yet, sends none, and the cached share may be unknown.
    @Test func sessionTokensDecodeWhenPresentAndDefaultToNilWhenAbsent() throws {
        let counted = #"{"sessionId":"s1","windowId":"w1","tabIndex":0,"taskId":null,"projectId":null,"agent":"claude","model":null,"state":"working","title":"","cwd":"/repo","tokens":{"input":936018,"cached":935988,"output":5625}}"#
        #expect(try JSONDecoder().decode(SessionInfo.self, from: Data(counted.utf8)).tokens
                == TokenTally(input: 936_018, cached: 935_988, output: 5_625))
        let unknownShare = #"{"sessionId":"s1","windowId":"w1","tabIndex":0,"taskId":null,"projectId":null,"agent":"grok","model":null,"state":"working","title":"","cwd":"/repo","tokens":{"input":12,"cached":null,"output":3}}"#
        #expect(try JSONDecoder().decode(SessionInfo.self, from: Data(unknownShare.utf8)).tokens?.cached == nil)
        let none = #"{"sessionId":"s2","windowId":"w1","tabIndex":1,"taskId":null,"projectId":null,"agent":"shell","model":null,"state":"idle","title":"","cwd":"/repo"}"#
        #expect(try JSONDecoder().decode(SessionInfo.self, from: Data(none.utf8)).tokens == nil)
    }

    /// A tally the app cannot read — a count too large for an `Int`, or not a tally at all — costs
    /// only that session's counts, never the session or the snapshot it came in.
    @Test func aSessionWhoseTokensCannotBeReadStillDecodesWithoutThem() throws {
        for tokens in [#"{"input":1e30,"cached":null,"output":3}"#, #""many""#] {
            let json = #"{"sessionId":"s1","windowId":"w1","tabIndex":0,"taskId":null,"projectId":null,"agent":"claude","model":null,"state":"working","title":"","cwd":"/repo","tokens":"# + tokens + "}"
            let session = try JSONDecoder().decode(SessionInfo.self, from: Data(json.utf8))
            #expect(session.sessionId == "s1")
            #expect(session.tokens == nil)
        }
    }

    /// C4: a daemon built from a different worktree can send a `SessionAgent`/`SessionState` raw
    /// value this app has never heard of. Decoding it to `.shell`/`.idle` keeps that one session
    /// from failing the whole snapshot, instead of a `.helperUnreachable` reconnect loop.
    @Test func unknownAgentAndStateDecodeToTheirDefaultsInsteadOfFailing() throws {
        let json = #"{"sessionId":"s1","windowId":"w1","tabIndex":0,"taskId":null,"projectId":null,"agent":"gremlin","model":null,"state":"pondering","title":"","cwd":"/repo"}"#
        let info = try JSONDecoder().decode(SessionInfo.self, from: Data(json.utf8))
        #expect(info.agent == .shell)
        #expect(info.state == .idle)
    }

    @Test func aSnapshotCarryingAnUnknownAgentOrStateStillDecodesAsAWhole() throws {
        let json = #"{"protocolVersion":1,"connected":true,"sessions":[{"sessionId":"s1","windowId":"w1","tabIndex":0,"taskId":null,"projectId":null,"agent":"gremlin","model":null,"state":"pondering","title":"","cwd":"/repo"}],"usage":{"claude":null,"codex":null}}"#
        let snapshot = try JSONDecoder().decode(DaemonSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.sessions.first?.agent == .shell)
        #expect(snapshot.sessions.first?.state == .idle)
    }

    @Test func theAppsWordsComeFromTheCodeNotTheHelpersMessage() {
        func said(_ code: DaemonError.Code) -> String { DaemonError(code: code, message: "Traceback (most recent call last)").userMessage }
        #expect(said(.timeout) == "Shellforge’s helper didn’t answer in time; it may still finish.")
        #expect(said(.incompatible) == "Shellforge’s helper is from another version.")
        #expect(said("something_newer") == "Shellforge’s helper ran into a problem.")
    }

    @Test func aSessionReportWritesEveryKeyTheDaemonReads() throws {
        let report = SessionReport(sessionId: "G", windowId: "pty-1", tabIndex: 0, commandLine: nil, jobPid: nil, title: "t",
                                   cwd: "/r", active: true, task: nil, project: nil)
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        #expect(Set(object.keys) == ["active", "commandLine", "cwd", "jobPid", "projectId", "sessionId", "tabIndex", "taskId", "title", "windowId"])
        #expect(object["commandLine"] is NSNull && object["taskId"] is NSNull)
    }

    @Test func theDaemonsITerm2FieldsAreReadButNotRequired() throws {
        let appMode = #"{"protocolVersion":1,"connected":true,"itermVersion":"Shellforge","itermAuthError":null,"itermCookieRequest":null,"sessions":[],"usage":{"claude":null,"codex":null}}"#
        #expect(try JSONDecoder().decode(DaemonSnapshot.self, from: Data(appMode.utf8)).itermVersion == "Shellforge")
        let bare = #"{"protocolVersion":1,"connected":true,"sessions":[],"usage":{"claude":null,"codex":null}}"#
        #expect(try JSONDecoder().decode(DaemonSnapshot.self, from: Data(bare.utf8)).connected)
    }
}
