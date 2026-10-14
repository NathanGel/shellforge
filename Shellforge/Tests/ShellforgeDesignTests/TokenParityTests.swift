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
                         "SidebarHeading", "SymbolMark", "FormField", "Input", "Select", "SegmentedControl", "Kbd", "SearchField"]
    /// Ported files that differ from AiTerm's on purpose (ledgered).
    static let changed: Set = ["FormField", "Input", "SegmentedControl", "Palette", "IconSource", "SidebarHeading", "Metrics", "Surface", "Badge"]
    /// SHA-256 of each ported file, normalised, as reviewed.
    static let baseline: [String: String] = [
        "Badge": "8d82c1df4269c88794a80451715afc2a1dd54b5c8f5fa5fec6036c0c0075ff78",
        "FormField": "d2450a5864c2a2acb674de92b35abcf2e6d081ff5cb2c8daf67dc2872fbbf46f",
        "Hairline": "ab5976604f277a70104f15faa8d6d8effaa90519135e36862a2d24d48231e4f0",
        "Input": "efe2209ee6317b2f79eb518517aa611c250e29d164861d3d23bc8c872cad4cce",
        "Kbd": "353eb6097c664e69e70ca5eeae00f6dd16fbd75c6731b9e15fa5a3fb13509609",
        "SearchField": "be937c4cb1723ca16f8b44691b96edd587f447a5139e6b478efc0b6b03db8c13",
        "SegmentedControl": "2c2d22dc1bc22cb14ce260f2792f6ff6c9f668922176dccfba1847b7c5b4ab4a",
        "Select": "1dd66bc87b8fdd973eb9dc19cdbf9ba6273a329a17b6895bd3ee0e96544621dd",
        "IconSource": "1c4233822c68d94be0a1d95aefdf0c27242b2a14b31839c4a5ef13c59be093df",
        "InterfaceScale": "8cd10c61121676480e5fae9e24d5e9499ee7babcb165739c16514f3174cda745",
        "Logos": "af2e1ee98ac438ca5bc59b58aa2fcffca6269ad502c2b1c73f78b875dfd7a4f5",
        "Metrics": "413664f2cb268cf9c9ee739b8e90182bf0fcdcaac5b522d7859d4d1195b5e01a",
        "Palette": "e22dd75448a63fa13305968a02cf50a1292ee0dc0e2920b375359825844e5051",
        "SidebarHeading": "920a10e24175cc889fa22c5437ca486ddebd7ee2605350795edb56138ebca38f",
        "Surface": "59282e263f6d4728cd2af4ec4e48ffbbf6b18557111a89a6a97e9d4fe89adf7e",
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
