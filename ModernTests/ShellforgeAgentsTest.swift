//
//  ShellforgeAgentsTest.swift
//  ModernTests
//
//  Any agent, as the app hosts it: the commands the bundle ships for agents' hooks and launches,
//  the ready-made agents beside them, the terminal signals counted per session, and OSC 777's
//  notify reaching the notification path that OSC 9 takes.
//

import ShellforgeCore
import XCTest
@testable import iTerm2SharedARC

final class ShellforgeAgentsTest: XCTestCase {
    private var hooks: URL {
        get throws { try XCTUnwrap(Bundle.main.resourceURL).appendingPathComponent("hooks", isDirectory: true) }
    }

    func testBundleShipsTheCommands() throws {
        let hooks = try hooks
        for name in ["shellforge-status", "shellforge-run"] {
            let path = hooks.appendingPathComponent(name).path
            XCTAssertTrue(FileManager.default.fileExists(atPath: path), "\(name) is missing from the bundle")
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path), "\(name) is not executable")
        }
        let agents = try FileManager.default.contentsOfDirectory(atPath: hooks.appendingPathComponent("agents").path)
        XCTAssertEqual(agents.filter { $0.hasSuffix(".json") }.count, 6)
    }

    @MainActor
    func testTheAppsToolsAreTheBundledOnes() throws {
        let tools = iTermShellforgeSidebar.agentTools
        XCTAssertEqual(tools.statusCommand, try hooks.appendingPathComponent("shellforge-status").path)
        XCTAssertEqual(tools.runner, try hooks.appendingPathComponent("shellforge-run"))
        XCTAssertNotNil(tools.readyMade)
    }

    @MainActor
    func testTypingEchoIsNotCounted() {
        defer { iTermShellforgeSignals.ended("t") }
        iTermShellforgeSignals.output("t", bytes: 100, sinceInput: 0.1)
        XCTAssertEqual(iTermShellforgeSignals.signals("t")?.outputBytes ?? 0, 0)
        iTermShellforgeSignals.output("t", bytes: 100, sinceInput: 2)
        XCTAssertEqual(iTermShellforgeSignals.signals("t")?.outputBytes, 100)
    }

    @MainActor
    func testAttentionIsCountedAndATabsEndForgetsIt() {
        iTermShellforgeSignals.attention("a")
        iTermShellforgeSignals.attention("a")
        XCTAssertEqual(iTermShellforgeSignals.signals("a")?.attention, 2)
        iTermShellforgeSignals.ended("a")
        XCTAssertNil(iTermShellforgeSignals.signals("a"))
    }

    /// Optional, so iTerm2's own screen delegates and test fakes need nothing for it; the caller
    /// checks respondsToSelector:.
    func testTheAttentionCallIsOptionalForScreenDelegates() throws {
        let proto = try XCTUnwrap(NSProtocolFromString("VT100ScreenDelegate"))
        let selector = NSSelectorFromString("screenShellforgeAttentionRequested")
        XCTAssertNotNil(protocol_getMethodDescription(proto, selector, false, true).name)
        XCTAssertNil(protocol_getMethodDescription(proto, selector, true, true).name)
    }

    func testOSC777NotifyIsANotification() {
        var incidentals = CVector()
        CVectorCreate(&incidentals, 1)
        defer { CVectorDestroy(&incidentals) }
        var bytes = Array("\u{1b}]777;notify;Build;All done\u{07}".utf8)
        let token = VT100Token()
        bytes.withUnsafeMutableBufferPointer { buf in
            var context = iTermParserContextMake(buf.baseAddress, Int32(buf.count))
            VT100XtermParser.decode(from: &context, incidentals: &incidentals, token: token,
                                    encoding: String.Encoding.utf8.rawValue, savedState: NSMutableDictionary())
        }
        XCTAssertEqual(token.type, XTERMCC_RXVT_EXTENSION)
        XCTAssertEqual(token.string, "notify;Build;All done")
        XCTAssertEqual(VT100Terminal.userNotificationMessage(osc777Payload: "notify;Build;All done"), "Build: All done")
        XCTAssertEqual(VT100Terminal.userNotificationMessage(osc777Payload: "notify;;All done"), "All done")
        XCTAssertEqual(VT100Terminal.userNotificationMessage(osc777Payload: "notify;Build"), "Build")
        XCTAssertNil(VT100Terminal.userNotificationMessage(osc777Payload: "preexec"))
        XCTAssertNil(VT100Terminal.userNotificationMessage(osc777Payload: "notify;;"))
    }
}
