import Foundation

/// Where feedback goes when the relay can't take it: Shellforge's own GitHub issue form.
public enum FeedbackLink {
    /// Browsers and GitHub refuse very long URLs; the full text goes on the clipboard beside the link.
    public static let maxURLLength = 7000
    private static let repo = "https://github.com/NathanGel/shellforge/issues"

    public static func issue(_ number: Int) -> URL {
        URL(string: "\(repo)/\(number)")!
    }

    /// The feedback form (`.github/ISSUE_TEMPLATE/feedback.yml`) with its fields filled in. `cut` is true
    /// when any text was shortened to fit.
    public static func form(_ feedback: FeedbackSubmission) -> (url: URL, cut: Bool) {
        var cut = false
        func limited(_ s: String?) -> String? {
            guard let s else { return nil }
            guard s.count > BugReportLink.maxDetails else { return s }
            cut = true
            return String(s.prefix(BugReportLink.maxDetails)) + BugReportLink.truncationNote
        }
        var good = limited(feedback.good)
        var bad = limited(feedback.bad)

        func url(_ good: String?, _ bad: String?) -> URL {
            var items = [URLQueryItem(name: "template", value: "feedback.yml"),
                         URLQueryItem(name: "version", value: feedback.version),
                         URLQueryItem(name: "macos", value: feedback.macos)]
            if let rating = feedback.rating { items.append(URLQueryItem(name: "rating", value: "\(rating)/5")) }
            if let good { items.append(URLQueryItem(name: "good", value: good)) }
            if let bad { items.append(URLQueryItem(name: "bad", value: bad)) }
            var parts = URLComponents(string: "\(repo)/new")!
            parts.queryItems = items
            return parts.url!
        }
        func fits(_ good: String?, _ bad: String?) -> Bool {
            url(good, bad).absoluteString.utf8.count <= maxURLLength
        }
        /// The longest `Character` prefix of `text`, plus the note, that makes the URL fit.
        func shortened(_ text: String, fits: (String) -> Bool) -> String {
            let characters = Array(text)
            var low = 0, high = characters.count
            while low < high {
                let mid = (low + high + 1) / 2
                if fits(String(characters[..<mid]) + BugReportLink.truncationNote) { low = mid } else { high = mid - 1 }
            }
            return String(characters[..<low]) + BugReportLink.truncationNote
        }

        if !fits(good, bad) {
            cut = true
            // Shorten the longer field first, then the other only if that wasn't enough.
            let goodFirst = (good?.count ?? 0) >= (bad?.count ?? 0)
            for shortenGood in [goodFirst, !goodFirst] where !fits(good, bad) {
                if shortenGood, let g = good {
                    good = shortened(g) { fits($0, bad) }
                } else if !shortenGood, let b = bad {
                    bad = shortened(b) { fits(good, $0) }
                }
            }
        }
        return (url(good, bad), cut)
    }
}
