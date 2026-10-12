// Ported from AiTerm (app/Sources/AiTerm/ExternalApps.swift), GPLv3, Laurens D'Hondt.
import AppKit

/// AiTerm's `ExternalApps.open(link:)`: a badge's link opens in the browser, and only a web page
/// opens — the links come from the workspace file and from Jira, and a `file:` or custom-scheme URL
/// in either must not launch whatever handles it.
enum ExternalLink {
    static func webURL(_ link: String?) -> URL? {
        guard let link, let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased()) else { return nil }
        return url
    }

    static func open(_ link: String?) {
        if let url = webURL(link) { NSWorkspace.shared.open(url) }
    }
}
