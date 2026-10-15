import Foundation

/// Where Shellforge's users report problems: its own GitHub issue forms (CONTRIBUTING.md), never
/// iTerm2's tracker — a Shellforge build's bugs are Shellforge's to hear about first.
public enum BugReportLink {
    /// The forms' chooser, for text that can only print a link.
    public static let chooser = "https://github.com/NathanGel/shellforge/issues/new/choose"
    private static let newIssue = "https://github.com/NathanGel/shellforge/issues/new"

    /// How much of a report a link carries; the whole report goes on the clipboard beside it.
    public static let maxDetails = 2000
    public static let truncationNote = "\n\n…(cut short: the full report is on your clipboard — paste it here)"

    /// The bug-report form (`.github/ISSUE_TEMPLATE/bug-report.yml`) with its fields filled in: GitHub
    /// fills a form's field from the query item named by its `id`.
    public static func form(version: String, macOS: String, title: String?, details: String?) -> URL {
        var items = [URLQueryItem(name: "template", value: "bug-report.yml"),
                     URLQueryItem(name: "version", value: version),
                     URLQueryItem(name: "macos", value: macOS)]
        if let title, !title.isEmpty { items.append(URLQueryItem(name: "title", value: "[Bug] " + title)) }
        if let details, !details.isEmpty {
            let cut = details.count > maxDetails ? String(details.prefix(maxDetails)) + truncationNote : details
            items.append(URLQueryItem(name: "actual", value: cut))
        }
        var parts = URLComponents(string: newIssue)!
        parts.queryItems = items
        return parts.url!
    }
}
