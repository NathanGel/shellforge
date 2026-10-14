// Ported from AiTerm (app/Sources/AiTermCore/Interface/BuildChannel.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// Whether the running bundle is a release or a local build. The Info.plist's `ShellforgeDevBuild`
/// is `$(SHELLFORGE_DEV_BUILD)`, which only the Development configuration sets (to `YES`); every
/// other build expands it to nothing. A dev build does not update itself.
public enum BuildChannel: Equatable, Sendable {
    case release, dev

    public static let infoKey = "ShellforgeDevBuild"

    /// `nil` (a bundle without an Info.plist) reads as release: it has no feed to update from
    /// either, so there is nothing for `.dev` to change.
    public init(infoDictionary: [String: Any]?) {
        switch infoDictionary?[Self.infoKey] {
        case let flag as Bool: self = flag ? .dev : .release
        case let text as String: self = ["yes", "true", "1"].contains(text.lowercased()) ? .dev : .release
        default: self = .release
        }
    }
}
