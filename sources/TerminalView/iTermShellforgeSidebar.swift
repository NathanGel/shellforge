//
//  iTermShellforgeSidebar.swift
//  Shellforge
//
//  Hands the Shellforge sidebar, which lives in the Shellforge package, to the Objective-C window
//  code, which cannot import a Swift package itself.
//

import AppKit
import ShellforgeUI

@objc(iTermShellforgeSidebar)
@MainActor
final class iTermShellforgeSidebar: NSObject {
    /// The sidebar column's width in points.
    @objc static var width: CGFloat { ShellforgeSidebar.width }

    /// A new sidebar view for one window.
    @objc static func makeView() -> NSView { ShellforgeSidebar.makeView() }
}
