//
//  ShellforgeSnapshotTest.swift
//  Shellforge
//
//  Writes a window with the sidebar to PNG, light and dark, for looking at the layout without screen
//  recording. Runs only with SHELLFORGE_SNAPSHOT_DIR set (TEST_RUNNER_SHELLFORGE_SNAPSHOT_DIR for
//  xcodebuild).
//

import XCTest
@testable import iTerm2SharedARC

@MainActor
final class ShellforgeSnapshotTest: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SHELLFORGE_SNAPSHOT_DIR"]?.isEmpty == false)
    }

    func testWriteSnapshots() throws {
        let directory = try XCTUnwrap(ProcessInfo.processInfo.environment["SHELLFORGE_SNAPSHOT_DIR"])
        let fixture = TerminalWindowTestFixture()
        defer { fixture.close() }
        fixture.window.setContentSize(NSSize(width: 1100, height: 700))
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            fixture.window.appearance = NSAppearance(named: appearance)
            let frameView = try XCTUnwrap(fixture.window.contentView?.superview)
            frameView.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("sidebar-\(name).png"))
        }
    }
}
