//
//  iTermShellforgeErrorLog.swift
//  Shellforge
//
//  The error log in the running app's data folder, and Help › Show Error Log, which shows it in Finder.
//

import AppKit
import ShellforgeCore

@objc(iTermShellforgeErrorLog)
@MainActor
final class iTermShellforgeErrorLog: NSObject {
    /// `logs/errors.log` in the running app's data folder, so a dev build keeps its own.
    static let log = ErrorLog(folder: iTermShellforgeSidebar.dataFolder.appendingPathComponent("logs", isDirectory: true),
                              version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")

    /// Starts recording, at launch. Not under unit tests, which run as the real bundle and must not
    /// write to its data folder.
    @objc static func configure() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        ErrorLogging.configure(log)
        DLog("Shellforge: error log at \(log.fileURL.path)")
    }

    /// Help › Show Error Log: the file selected in Finder, an empty one made first if nothing has
    /// been recorded yet.
    @objc static func showErrorLog() {
        log.createIfMissing()
        NSWorkspace.shared.activateFileViewerSelecting([log.fileURL])
    }
}
