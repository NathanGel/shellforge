import AppKit
import Testing
import ShellforgeTestHeadless

/// A test run's windows stay off the person's screen: shown as AppKit sees it, but transparent and
/// click-through, unless SHELLFORGE_TESTS_VISIBLE=1 asks to watch them.
@MainActor @Suite(.enabled(if: ShellforgeTestWindowsHidden(), "SHELLFORGE_TESTS_VISIBLE=1 shows the windows"))
struct HeadlessWindowsTests {
    @Test func aWindowATestShowsIsInvisibleAndStillKeyable() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 100, height: 22))
        window.contentView?.addSubview(field)

        window.makeKeyAndOrderFront(nil)

        #expect(window.isVisible)
        #expect(window.alphaValue == 0)
        #expect(window.ignoresMouseEvents)
        #expect(window.makeFirstResponder(field))
    }

    /// A sheet is a window of its own, shown by AppKit rather than the test.
    @Test func aSheetIsInvisibleToo() throws {
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 50), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false; sheet.isReleasedWhenClosed = false
        defer { parent.endSheet(sheet); parent.close() }
        parent.orderFront(nil)
        parent.beginSheet(sheet, completionHandler: nil)
        #expect(sheet.alphaValue == 0)
    }
}
