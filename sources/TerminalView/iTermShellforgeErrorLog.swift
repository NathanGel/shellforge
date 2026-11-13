//
//  iTermShellforgeErrorLog.swift
//  Shellforge
//
//  The error log in the running app's data folder, and Help › Show Error Log, which shows it in Finder.
//

import AppKit
import ShellforgeCore
import ShellforgeDesign

@objc(iTermShellforgeErrorLog)
@MainActor
final class iTermShellforgeErrorLog: NSObject {
    /// `logs/errors.log` in the running app's data folder, so a dev build keeps its own.
    static let log = ErrorLog(folder: iTermShellforgeSidebar.dataFolder.appendingPathComponent("logs", isDirectory: true),
                              version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")  // Localization unneeded

    /// Starts recording, at launch. Not under unit tests, which run as the real bundle and must not
    /// write to its data folder.
    @objc static func configure() {
        installLogSinks()
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        ErrorLogging.configure(log)
        DLog("Shellforge: error log at \(log.fileURL.path)")
    }

    /// The package's log lines in iTerm2's own logs: its debug lines in the debug log, its errors in
    /// the retrospective log as well. Under unit tests too, where the debug log is just as useful.
    private static func installLogSinks() {
        LogSink.install { level, line in
            switch level {
            case .debug: DLog("Shellforge: \(line)")
            case .release: RLog("Shellforge: \(line)")
            }
        }
        DesignLog.install { line in DLog("Shellforge: \(line)") }
    }

    /// Help › Show Error Log: the file selected in Finder, an empty one made first if nothing has
    /// been recorded yet.
    @objc static func showErrorLog() {
        log.createIfMissing()
        NSWorkspace.shared.activateFileViewerSelecting([log.fileURL])
    }
}
