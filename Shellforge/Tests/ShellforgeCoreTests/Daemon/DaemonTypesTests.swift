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

    @Test func aCustomAgentDecodesAndEncodesBackUnchanged() throws {
        let decoded = try JSONDecoder().decode(SessionAgent.self, from: Data(#""custom:gemini""#.utf8))
        #expect(decoded == .custom("gemini"))
        #expect(decoded.customId == "gemini")
        #expect(String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self) == #""custom:gemini""#)
        #expect(try JSONDecoder().decode(SessionAgent.self, from: Data(#""claude""#.utf8)) == .claude)
    }

    @Test func aCustomIdOfSixtyFourCharactersIsValidAndOneOfSixtyFiveIsNot() {
        #expect(SessionAgent(rawValue: "custom:" + String(repeating: "a", count: 64)) == .custom(String(repeating: "a", count: 64)))
        #expect(SessionAgent(rawValue: "custom:" + String(repeating: "a", count: 65)) == nil)
    }

    @Test(arguments: ["custom:", "custom:a b", "robot", "custom:" + String(repeating: "a", count: 65)])
    func anInvalidCustomOrUnknownAgentIsAShell(_ raw: String) throws {
        #expect(SessionAgent(rawValue: raw) == nil)
        #expect(try JSONDecoder().decode(SessionAgent.self, from: Data("\"\(raw)\"".utf8)) == .shell)
    }

    @Test func anAgentIdGivesABuiltInsCaseOrACustomOne() {
        #expect(SessionAgent(agentId: "codex") == .codex)
        #expect(SessionAgent(agentId: "gemini") == .custom("gemini"))
        #expect(SessionAgent.builtIns == [.claude, .codex, .grok, .pi])
        #expect(SessionAgent.claude.customId == nil)
    }

    @Test func aCustomTabsStatusIsGuessedUntilItsFirstReport() throws {
        func session(_ agent: String, reportedAt: String) -> String {
            #"{"sessionId":"s1","windowId":"w1","tabIndex":0,"taskId":null,"projectId":null,"agent":"\#(agent)","model":null,"state":"working","title":"t","cwd":"/r"\#(reportedAt)}"#
        }
        func decode(_ json: String) throws -> SessionInfo { try JSONDecoder().decode(SessionInfo.self, from: Data(json.utf8)) }
        let guessed = try decode(session("custom:gemini", reportedAt: ""))
        #expect(guessed.reportedAt == nil && guessed.statusIsGuessed)
        #expect(try decode(session("custom:gemini", reportedAt: #","reportedAt":null"#)).statusIsGuessed)
        let reported = try decode(session("custom:gemini", reportedAt: #","reportedAt":1000.5"#))
        #expect(reported.reportedAt == 1000.5 && !reported.statusIsGuessed)
        #expect(try !decode(session("claude", reportedAt: "")).statusIsGuessed)
    }

    @Test func aSessionReportWritesTheCustomAgentAndSignalsAsNullWhenAbsent() throws {
        let report = SessionReport(sessionId: "G", windowId: "pty-1", tabIndex: 0, commandLine: nil, jobPid: nil, title: "t",
                                   cwd: "/r", active: true, task: nil, project: nil)
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        #expect(object["agentId"] is NSNull && object["outputBytes"] is NSNull && object["attention"] is NSNull)
        let sent = SessionReport(sessionId: "G", windowId: "pty-1", tabIndex: 0, commandLine: nil, jobPid: nil, title: "t",
                                 cwd: "/r", active: true, task: nil, project: nil, agentId: "gemini", outputBytes: 9, attention: 2)
        let back = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(sent)) as? [String: Any])
        #expect(back["agentId"] as? String == "gemini" && back["outputBytes"] as? Int == 9 && back["attention"] as? Int == 2)
    }

    @Test func aSessionReportWritesEveryKeyTheDaemonReads() throws {
        let report = SessionReport(sessionId: "G", windowId: "pty-1", tabIndex: 0, commandLine: nil, jobPid: nil, title: "t",
                                   cwd: "/r", active: true, task: nil, project: nil)
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        #expect(Set(object.keys) == ["active", "agentId", "attention", "commandLine", "cwd", "jobPid", "outputBytes", "projectId", "sessionId", "tabIndex", "taskId", "title", "windowId"])
        #expect(object["commandLine"] is NSNull && object["taskId"] is NSNull)
    }

    @Test func theDaemonsITerm2FieldsAreReadButNotRequired() throws {
        let appMode = #"{"protocolVersion":1,"connected":true,"itermVersion":"Shellforge","itermAuthError":null,"itermCookieRequest":null,"sessions":[],"usage":{"claude":null,"codex":null}}"#
        #expect(try JSONDecoder().decode(DaemonSnapshot.self, from: Data(appMode.utf8)).itermVersion == "Shellforge")
        let bare = #"{"protocolVersion":1,"connected":true,"sessions":[],"usage":{"claude":null,"codex":null}}"#
        #expect(try JSONDecoder().decode(DaemonSnapshot.self, from: Data(bare.utf8)).connected)
    }

    @Test func customSessionCarriesSignals() {
        let agents = [AgentDefinition(id: "gemini", name: "Gemini", command: "gemini")]
        var signals = TerminalSignals()
        signals.output(900, sinceInput: 5); signals.attentionRequested()
        let vars: [String: Any] = [SessionReport.Variable.commandLine: "node /opt/bin/gemini"]
        let r = SessionReport.reading(sessionId: "G", windowId: "W", tabIndex: 0, active: true, value: { vars[$0] },
                                      taskAgent: { _ in nil }, agents: agents, signals: { $0 == "G" ? signals : nil })
        #expect(r.agentId == "gemini" && r.outputBytes == 900 && r.attention == 1)
    }

    @Test func builtInSessionCarriesNone() {
        let task = "6f0e2c1a-9b3d-4e5f-8a7b-0c1d2e3f4a5b"
        let vars: [String: Any] = [SessionReport.Variable.commandLine: "claude", ShellforgeTags.task: task]
        let r = SessionReport.reading(sessionId: "G", windowId: "W", tabIndex: 0, active: true, value: { vars[$0] },
                                      taskAgent: { _ in "claude" }, agents: [], signals: { _ in TerminalSignals() })
        #expect(r.agentId == nil && r.outputBytes == nil && r.attention == nil)
    }
}
