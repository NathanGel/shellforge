// Ported from AiTerm (app/Tests/AiTermCoreTests/WireContractTests.swift), GPLv3, Laurens D'Hondt.
import Foundation
import Testing
@testable import ShellforgeCore

/// The app's half of the wire contract with the daemon. The daemon's suite
/// (`Shellforge/daemon/tests/test_wire_contract.py`) writes a golden frame of every event, reply and error
/// code, as a running daemon sends them, and a manifest of its names, into `daemon/tests/wire/`,
/// and fails while those differ from what it sends. Here each frame is read with the decoders
/// the client reads the socket with, and every name with the app's own: so a field, event, method
/// or code renamed on one side fails one suite or the other, not the app at runtime.
@Suite struct WireContractTests {
    static let wire = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("daemon/tests/wire")

    struct Manifest: Decodable {
        var protocolVersion: Int, maxFrameBytes: Int
        var events: [String], methods: [String], errorCodes: [String]
        /// The raw values of a session's `agent` and `state`.
        var sessionAgents: [String], sessionStates: [String]
        /// The file, or files, that show each name.
        var fixtures: Fixtures
        struct Fixtures: Decodable { var events: [String: String], replies: [String: [String]], errors: [String: String] }
    }

    static func manifest() throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: wire.appendingPathComponent("manifest.json")))
    }

    static func frame(_ file: String) throws -> Data { try Data(contentsOf: wire.appendingPathComponent(file)) }

    /// A frame as the untyped tree the daemon built, to compare what the app decoded with.
    static func tree(_ line: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
    }

    @Test func theAppNamesWhatTheDaemonNames() throws {
        let manifest = try Self.manifest()
        #expect(manifest.protocolVersion == DaemonProtocol.version)
        #expect(manifest.maxFrameBytes == DaemonProtocol.maximumFrameBytes)
        // The app names a subset: the daemon also serves and sends its iTerm2 bridge's, which
        // Shellforge never uses. Every one the app names must be the daemon's.
        #expect(Set(DaemonEventName.allCases.map(\.rawValue)).isSubset(of: Set(manifest.events)))
        #expect(Set(DaemonMethod.allCases.map(\.rawValue)).isSubset(of: Set(manifest.methods)))
        #expect(Set(manifest.errorCodes) == Set(DaemonError.Code.daemonCodes.map(\.rawValue)))
        // Read leniently — one the app does not know is a shell, or idle — so only this says that
        // the daemon has grown one.
        #expect(Set(manifest.sessionAgents) == Set(SessionAgent.allCases.map(\.rawValue)))
        #expect(Set(manifest.sessionStates) == Set(SessionState.allCases.map(\.rawValue)))
    }

    @Test(arguments: DaemonEventName.allCases) func everyEventReadsAsItsName(_ name: DaemonEventName) throws {
        let line = try Self.frame(#require(Self.manifest().fixtures.events[name.rawValue]))
        let header = try JSONDecoder().decode(Header.self, from: line)
        #expect(header.event == name.rawValue && header.id == nil && header.error == nil)
        let payload = try #require(Self.tree(line)["payload"] as? [String: Any])
        switch (name, try DaemonClient.decodeEvent(name.rawValue, from: line)) {
        case (.sessionClosed, .sessionClosed(let id)): #expect(id == payload["sessionId"] as? String)
        case (.sessionOpened, .sessionOpened(let session)), (.sessionChanged, .sessionChanged(let session)):
            try Self.expectSame(session, payload)
        case (.usageChanged, .usageChanged(let usage)): try Self.expectSame(usage, payload)
        case (_, let event): Issue.record("\(name.rawValue) read as \(event)")
        }
    }

    @Test(arguments: DaemonMethod.allCases) func everyReplyReadsAsTheTypeItsRequestAwaits(_ method: DaemonMethod) throws {
        let files = try #require(Self.manifest().fixtures.replies[method.rawValue])
        #expect(!files.isEmpty)
        let decoder = JSONDecoder()
        for file in files {
            let line = try Self.frame(file)
            let header = try decoder.decode(Header.self, from: line)
            #expect(header.id != nil && header.event == nil && header.error == nil, "\(file)")
            let result = try Self.tree(line)
            func read<R: Decodable>(_: R.Type) throws -> R { try DaemonClient.result(R.self, from: line, using: decoder) }
            func field(_ key: String) throws -> Any? { try #require(result["result"] as? [String: Any])[key] }
            switch method {
            case .sessionsMarkSeen: #expect(try read(DaemonClient.ChangedResult.self).changed == field("changed") as? Int)
            case .sessionsUpdate: _ = try read(DaemonClient.Empty.self)
            case .workspaceSnapshot: try Self.expectSame(read(DaemonSnapshot.self), #require(result["result"] as? [String: Any]))
            // ctl's, and usage.get also the liveness check: read as the models the app shares with it.
            case .sessionsList: try Self.expectSame(read([SessionInfo].self), #require(result["result"]))
            case .usageGet: try Self.expectSame(read(UsageSnapshot.self), #require(result["result"]))
            }
        }
    }

    @Test(arguments: DaemonError.Code.daemonCodes) func everyErrorCodeArrivesAsTheCodeTheAppNamesIt(_ code: DaemonError.Code) throws {
        let line = try Self.frame(#require(Self.manifest().fixtures.errors[code.rawValue]))
        let body = try #require(try JSONDecoder().decode(Header.self, from: line).error)
        let error = DaemonError(code: body.code, message: body.message)
        #expect(error.code == code)
        #expect(!error.message.isEmpty)
        #expect(error.isNotFound == (code == .notFound))
        #expect(error.isMismatch == (code == .unknownMethod))
    }

    /// What the app read is what the daemon sent: every field the daemon sent, at every level, is
    /// one the app's type stores, and the other way round, so a renamed field fails even while its
    /// value is null; and the value read back out, nulls aside, is the daemon's.
    static func expectSame(_ value: Any, _ json: Any, sourceLocation: SourceLocation = #_sourceLocation) throws {
        expectSameFields(value, json, at: "", sourceLocation: sourceLocation)
        switch value {
        case let value as any Encodable: try expectSameValues(value, json, sourceLocation: sourceLocation)
        default: break
        }
        if let snapshot = value as? DaemonSnapshot, let json = json as? [String: Any] {
            // Decodable only: its own fields here, its sessions and usage above as their own types.
            try expectSameValues(snapshot.sessions, json["sessions"] as Any, sourceLocation: sourceLocation)
            try expectSameValues(snapshot.usage, json["usage"] as Any, sourceLocation: sourceLocation)
            #expect(snapshot.protocolVersion == json["protocolVersion"] as? Int, sourceLocation: sourceLocation)
            #expect(snapshot.connected == json["connected"] as? Bool, sourceLocation: sourceLocation)
            #expect(snapshot.itermVersion == json["itermVersion"] as? String, sourceLocation: sourceLocation)
            #expect(snapshot.itermAuthError == json["itermAuthError"] as? String, sourceLocation: sourceLocation)
            #expect(snapshot.itermCookieRequest == json["itermCookieRequest"] as? Int, sourceLocation: sourceLocation)
        }
    }

    private static func expectSameFields(_ value: Any, _ json: Any, at path: String, sourceLocation: SourceLocation) {
        let mirror = Mirror(reflecting: value)
        switch (mirror.displayStyle, json) {
        case (.optional, _):
            if let wrapped = mirror.children.first?.value { expectSameFields(wrapped, json, at: path, sourceLocation: sourceLocation) }
        case (.struct, let object as [String: Any]):
            let stored = Set(mirror.children.compactMap(\.label))
            #expect(stored == Set(object.keys), "the fields of \(type(of: value)) at \(path.isEmpty ? "the top" : path)", sourceLocation: sourceLocation)
            for child in mirror.children {
                guard let label = child.label, let field = object[label] else { continue }
                expectSameFields(child.value, field, at: "\(path).\(label)", sourceLocation: sourceLocation)
            }
        case (.collection, let array as [Any]):
            for (index, (element, field)) in zip(mirror.children.map(\.value), array).enumerated() {
                expectSameFields(element, field, at: "\(path)[\(index)]", sourceLocation: sourceLocation)
            }
        default: break // a value, an enum's raw value among them
        }
    }

    private static func expectSameValues(_ value: any Encodable, _ json: Any, sourceLocation: SourceLocation) throws {
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: .fragmentsAllowed)
        #expect(withoutNulls(encoded) as? NSObject == withoutNulls(json) as? NSObject, "\(type(of: value))", sourceLocation: sourceLocation)
    }

    /// The app's encoders leave a nil out where the daemon writes null.
    private static func withoutNulls(_ json: Any) -> Any {
        switch json {
        case let object as [String: Any]: object.filter { !($0.value is NSNull) }.mapValues(withoutNulls)
        case let array as [Any]: array.map(withoutNulls)
        default: json
        }
    }
}
