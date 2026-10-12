import AppKit
import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

@MainActor @Suite(.serialized) struct BackpackReviewTests {
    final class Recorder { var lines: [String] = [] }

    private func controller(_ fake: FakeBackpack, toasts: Recorder) -> BackpackController {
        BackpackController(ports: fake.ports, settings: fake.settings, tickInterval: .milliseconds(20),
                           retryDelays: [.milliseconds(10)], toast: { toasts.lines.append($0) })
    }

    /// A cancelled password prompt, a failed `visudo` check or an account name a rule cannot hold:
    /// nothing is written, and the person is told, not left looking at the same Allow… button.
    @Test func aRefusedAllowSaysWhy() async {
        let fake = FakeBackpack(), toasts = Recorder()
        fake.lid.allowed = false
        fake.installer.succeeds = false
        let backpack = controller(fake, toasts: toasts)
        await backpack.setUp()
        #expect(toasts.lines.last == BackpackController.ruleNotInstalled)
        #expect(!backpack.setup.sleepRule)
    }

    /// After a crash with lid sleep off, a launch that cannot put it back says so, and keeps trying.
    @Test func aFailedRestoreAtLaunchIsSaidAndRetried() async {
        let fake = FakeBackpack(), toasts = Recorder()
        fake.settings.engaged = true
        fake.lid.succeeds = false
        let backpack = controller(fake, toasts: toasts)
        await backpack.launch()
        #expect(toasts.lines.contains(BackpackController.restoreFailed))
        fake.lid.succeeds = true
        await eventually { !fake.settings.engaged }
        backpack.shutdown()
    }

    /// ⌘B opens the sheet on the key window's sidebar, never an arbitrary one, and a closed window
    /// is forgotten.
    @Test func commandBOpensOnTheKeyWindowsSidebarAndForgetsClosedOnes() {
        let sheets = BackpackSheets()
        final class Opened { var names: [String] = [] }
        let opened = Opened()
        let b = NSObject()
        // Window `a` lives and closes inside a pool of its own: left to the test's, an autoreleased
        // reference could keep it alive past its close under a busy parallel run.
        autoreleasepool {
            let a = NSObject()
            sheets.register(a) { opened.names.append("a") }
            sheets.register(b) { opened.names.append("b") }
            #expect(sheets.present(for: b))
            #expect(opened.names == ["b"])
            #expect(!sheets.present(for: nil), "no window of ours is key: nothing opens somewhere arbitrary")
            #expect(sheets.count == 2)
        }
        #expect(sheets.count == 1, "a closed window's sidebar is not kept")
        #expect(opened.names == ["b"])
    }
}
