import AppKit
import ShellforgeCore

/// Every "report a bug" in the app goes to Shellforge's own GitHub forms (`BugReportLink`), with
/// this build's version and the Mac's macOS filled in — never iTerm2's tracker or crash server.
@objc(iTermShellforgeBugReport)
final class iTermShellforgeBugReport: NSObject {
    /// The forms' chooser, for text that can only print a link.
    @objc static var chooserURLString: String { BugReportLink.chooser }

    /// The bug-report form, with `title` and the start of `details` filled in when given.
    @objc static func formURL(title: String?, details: String?) -> URL {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return BugReportLink.form(version: version, macOS: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                                  title: title, details: details)
    }

    /// Copies the whole `report` — a link can carry only its start — and opens the form.
    @objc static func open(title: String?, report: String?) {
        if let report, !report.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
        }
        NSWorkspace.shared.open(formURL(title: title, details: report))
    }
}
