import AppKit
import Testing
@testable import ShellforgeTestSupport

/// A test that reads pixels draws at 2× whatever screens are attached: the view's own choice
/// follows the displays, and a 1× monitor beside a Retina one moved a measure by whole points.
@MainActor @Suite struct SnapshotTests {
    @Test func snapshotsAreTwiceThePointSize() throws {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 7))
        let bitmap = try #require(Snapshot.bitmap(of: view))
        #expect(bitmap.pixelsWide == 20 && bitmap.pixelsHigh == 14)
        #expect(bitmap.size == NSSize(width: 10, height: 7))
    }
}
