//
//  iTermShellforgeUpdates.swift
//  Shellforge
//
//  Check for Updates… for the Objective-C app delegate: Shellforge's own GitHub releases through
//  ShellforgeUI's UpdateController, in place of iTerm2's Sparkle feed.
//

import AppKit
import ShellforgeUI

@objc(iTermShellforgeUpdates)
@MainActor
final class iTermShellforgeUpdates: NSObject {
    /// One for the app, made on first use: the running bundle's version, feed and build channel.
    private static let controller = UpdateController.live(prompter: ModalPrompter())

    /// The menu item's action. The check runs to its last alert on its own.
    @objc static func checkForUpdates() {
        Task { await controller.checkForUpdates() }
    }

    /// The menu item is disabled while a check or an update is under way.
    @objc static func isBusy() -> Bool { controller.isBusy }

    /// At launch: report an update the helper could not install, then clear `Updates/`.
    @objc static func finishPreviousUpdate() {
        Task { await controller.finishPreviousUpdate() }
    }
}
