// Ported from AiTerm (app/Sources/AiTerm/Views/CodeHost+Review.swift), GPLv3, Laurens D'Hondt.
import ShellforgeCore
import ShellforgeDesign

/// What a review's host changes on screen: its mark, and what New Review calls its requests.
extension CodeHost {
    var brand: Brand { self == .gitHub ? Palette.github : Palette.gitlab }
    /// "merge request" or "pull request", for a sentence.
    var reviewNoun: String { self == .gitHub ? "pull request" : "merge request" }
    var reviewField: String { self == .gitHub ? "Pull request (optional)" : "Merge request (optional)" }
    var reviewPlaceholder: String { "Search by \(self == .gitHub ? "#" : "!")number, title or branch" }
    var reviewHint: String { "Select a \(reviewNoun) to fill in the name and branch." }
}
