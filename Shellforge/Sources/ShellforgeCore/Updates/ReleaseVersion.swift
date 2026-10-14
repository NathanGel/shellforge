// Ported from AiTerm (app/Sources/AiTermCore/Updates/ReleaseVersion.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// A release's `major.minor.patch`, from a tag such as `v0.10.0` or a bundle's
/// `CFBundleShortVersionString`. Ordered numerically, so `0.10.0` is newer than `0.9.2`. Anything
/// that is not exactly three runs of digits — a pre-release suffix, a fourth part, iTerm2's own
/// `unknown` or `3.7.dev` — is not a version.
public struct ReleaseVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int, minor: Int, patch: Int

    public init(major: Int, minor: Int, patch: Int) { self.major = major; self.minor = minor; self.patch = patch }

    public init?(_ text: String) {
        var trimmed = Substring(text.trimmingCharacters(in: .whitespaces))
        if trimmed.hasPrefix("v") { trimmed = trimmed.dropFirst() }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        // `Int("+1")` parses, so the digits are checked before the conversion is trusted.
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) }),
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]) else { return nil }
        self.init(major: major, minor: minor, patch: patch)
    }

    public static func < (a: ReleaseVersion, b: ReleaseVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
