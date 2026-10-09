import CryptoKit
import Foundation
import Testing

/// The design system is AiTerm's, unchanged, and stays as reviewed. Two checks, each on whole files
/// with comments and blank lines set aside (the credit header and the notes differ, nothing else may):
///
/// - Every ported file matches a baseline reviewed in this repository. It never skips: any edit, a
///   value, a computed colour, a private constant, fails here until the baseline is moved on purpose.
/// - Where `~/aiterm` has the commit the port was taken from, every ported file but `FormField` (the
///   one deliberate change, without `FrontToBackStack`) equals AiTerm's there, names swapped. The
///   commit is pinned, so AiTerm's own work in progress never turns this red; moving it is a re-port.
@Suite struct TokenParityTests {
    static let pinned = "c1f851e574d0c8dd45a95957449c8798d60b65f4"
    static let ported = ["Palette", "Metrics", "Surface", "InterfaceScale", "Logos", "IconSource", "Badge", "Hairline",
                         "SidebarHeading", "SymbolMark", "FormField"]
    /// Ported files that differ from AiTerm's on purpose (ledgered).
    static let changed: Set = ["FormField"]
    /// SHA-256 of each ported file, normalised, as reviewed.
    static let baseline: [String: String] = [
        "Badge": "cde41a8fd041703814a5212741732e5cdd33108a0f5a34e811a15d7f27d67081",
        "FormField": "d2450a5864c2a2acb674de92b35abcf2e6d081ff5cb2c8daf67dc2872fbbf46f",
        "Hairline": "ab5976604f277a70104f15faa8d6d8effaa90519135e36862a2d24d48231e4f0",
        "IconSource": "0c382ef8d9e44a1d3ba36767a8aa73ff1d9bdf0fb89217efe798e52267134794",
        "InterfaceScale": "8cd10c61121676480e5fae9e24d5e9499ee7babcb165739c16514f3174cda745",
        "Logos": "af2e1ee98ac438ca5bc59b58aa2fcffca6269ad502c2b1c73f78b875dfd7a4f5",
        "Metrics": "a763271398c338d01e3b9776a8b393ca1c5c64aba662a05358dcdabaf2587805",
        "Palette": "ed932e6ded1316e4e0058a34875684ba3219587b5bd3754daa62aa5f6150d9fa",
        "SidebarHeading": "8ad7d4a95d09e4f7fdb6ca01ac287f59a03ec0b7511ed9ccf0866d60b19d772b",
        "Surface": "9c7e52c35f0b007b2750a5f455243811e1065f53ea57948dd3d4f5ed11f4c282",
        "SymbolMark": "4e2801b33a0284b0ab889398eaac1a6164465feed0a8a177922b41501ae61cc5",
    ]

    private static let ours = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/ShellforgeDesign")
    private static let aitermRepo = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("aiterm")

    /// Code only: comment lines and blank lines dropped, each line trimmed, AiTerm's names Shellforge's.
    static func normalised(_ text: String) -> String {
        text.replacingOccurrences(of: "AiTerm", with: "Shellforge").split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("//") }
            .joined(separator: "\n")
    }

    private static func ours(_ file: String) throws -> String {
        try String(contentsOf: ours.appendingPathComponent("\(file).swift"), encoding: .utf8)
    }

    @Test(arguments: ported)
    func everyPortedFileIsAsReviewed(file: String) throws {
        let digest = SHA256.hash(data: Data(Self.normalised(try Self.ours(file)).utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(Self.baseline[file] == digest, "\(file).swift changed since it was reviewed — its digest is \(digest)")
    }

    /// AiTerm's file at the pinned commit, or nil when this machine has no such checkout.
    private static func aiterm(_ file: String) -> String? {
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", aitermRepo.path, "show", "\(pinned):app/Sources/AiTermUI/\(file).swift"]
        let out = Pipe()
        git.standardOutput = out
        git.standardError = FileHandle.nullDevice
        guard (try? git.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        git.waitUntilExit()
        return git.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
    }

    static let aitermAvailable = aiterm("Palette") != nil

    @Test(.enabled(if: TokenParityTests.aitermAvailable), arguments: ported.filter { !changed.contains($0) })
    func everyPortedFileIsAiTermsAtThePinnedCommit(file: String) throws {
        let theirs = try #require(Self.aiterm(file))
        #expect(Self.normalised(try Self.ours(file)) == Self.normalised(theirs), "\(file).swift is not AiTerm's at \(Self.pinned)")
    }
}
