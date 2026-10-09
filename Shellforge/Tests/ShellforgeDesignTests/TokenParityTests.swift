import Foundation
import Testing

/// The tokens are AiTerm's, unchanged: each ported token file, with AiTerm's names swapped for
/// Shellforge's, declares exactly the `static let` lines AiTerm's does. A value changed in the port
/// fails here before it reaches a pixel.
@Suite struct TokenParityTests {
    private static let ours = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/ShellforgeDesign")
    static let aiterm = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("aiterm/app/Sources/AiTermUI")

    private func declarations(_ url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("public static let") || $0.hasPrefix("static let") || $0.hasPrefix("case ") }
            .map { $0.replacingOccurrences(of: "AiTerm", with: "Shellforge") }
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: TokenParityTests.aiterm.path)),
          arguments: ["Palette.swift", "Metrics.swift", "Surface.swift", "InterfaceScale.swift", "Logos.swift", "IconSource.swift", "Badge.swift"])
    func everyTokenMatchesAiTerms(file: String) throws {
        #expect(try declarations(Self.ours.appendingPathComponent(file)) == declarations(Self.aiterm.appendingPathComponent(file)))
    }
}
