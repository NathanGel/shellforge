// Ported from AiTerm (app/Tests/AiTermUITests/DesignRulesTests.swift), GPLv3, Laurens D'Hondt.
import Foundation
import Testing

/// The README's boundaries, read off the source: nothing in `ShellforgeDesign` imports the rest of
/// the package, and no view writes a colour, a text size or a length of its own — the design
/// system's components and the sidebar's views alike. Every Swift file under
/// `Sources/ShellforgeDesign` and `Sources/ShellforgeUI` is read, subfolders included. Comments
/// are skipped — a doc comment that names `.white` is not a violation — and string literals are
/// too, so a `//` inside one (an SVG's `http://`) does not cut the line short.
struct DesignRulesTests {
    /// What a view may not write, each with where its value comes from instead.
    private enum Rule: String, CaseIterable {
        /// Rule 1: a literal colour — a `Palette` member instead.
        case colour
        /// Rule 1: a colour derived from a token where it is used — a named `Palette` member instead.
        case derivedColour
        /// Rule 2: a text size of the system's rather than a `Typography` style.
        case font
        /// Rule 2: a padding, spacing, corner radius, offset or frame written as a number — a
        /// `Metrics` member, or a view's own named one-off, instead. Zero is no size, and is allowed.
        /// One line at a time and by shape, so it does not see a number on a continuation line, a
        /// frame's number after an argument with parentheses (`.frame(width: f(x), height: 18)`), or
        /// lengths written elsewhere — `Spacer(minLength:)`, `EdgeInsets(top:…)`, `.lineSpacing(_:)`.
        /// Those are held by review.
        case length

        var pattern: NSRegularExpression {
            switch self {
            case .colour: DesignRulesTests.colourLiteral
            case .derivedColour: DesignRulesTests.derivedColour
            case .font: DesignRulesTests.systemFont
            case .length: DesignRulesTests.lengthLiteral
            }
        }

        /// The one file that writes the rule's values, as a path under `Sources`.
        var home: String? {
            switch self {
            case .colour: "ShellforgeDesign/Palette.swift"
            case .font: "ShellforgeDesign/Metrics.swift"
            case .derivedColour, .length: nil
            }
        }
    }

    /// A literal that is allowed where it stands, with the reason. Matched by file (a path under
    /// `Sources`), rule and a piece of the offending line, so an entry covers one site rather than
    /// a whole file. These are the README's one-offs: a shadow, a weight that shares a colour's
    /// name, a stroke, and a glyph sized as a fraction of the mark or image it is drawn in.
    private struct Exception {
        let file: String
        let rule: Rule
        let line: String
        let reason: String
    }

    private static let exceptions = [
        Exception(file: "ShellforgeDesign/ControlChrome.swift", rule: .colour, line: ".shadow(color: .black.opacity(",
                  reason: "a shadow's black is part of its geometry, which the README leaves untokenised"),
        Exception(file: "ShellforgeUI/Sidebar/VendorMark.swift", rule: .font, line: ".font(.system(size: size * 0.36",
                  reason: "the shell mark's chevron, sized as a fraction of the mark it is drawn in"),
        // The sidebar and the Agent hooks sheet as M1a and M1c-3a drew them, before the design system
        // came: one exception per line, as every other, until M1b-2 rebuilds both on ShellforgeDesign
        // and deletes these. The stale check below then proves none is left.
        Exception(file: "ShellforgeDesign/Metrics.swift", rule: .colour, line: "case .black: nsWeight = .black",
                  reason: "Font.Weight.black mapped to NSFont.Weight.black: a weight, not a colour"),
        Exception(file: "ShellforgeDesign/Hairline.swift", rule: .length, line: ".frame(height: 1)",
                  reason: "the hairline is a one-point stroke, which does not scale, not a length on the scale"),
        Exception(file: "ShellforgeDesign/IconSource.swift", rule: .font, line: ".font(.system(size: size))",
                  reason: "an SF Symbol drawn at the icon's size, which its caller passes from Metrics"),
        Exception(file: "ShellforgeDesign/Logos.swift", rule: .font, line: ".font(.system(size: size * 0.9",
                  reason: "the SF Symbol standing in for a missing logo, sized as a fraction of that logo"),
        Exception(file: "ShellforgeDesign/TerminalPalette.swift", rule: .colour, line: "static let surface = NSColor.windowBackgroundColor",
                  reason: "a source of the terminal match's palette, resolved into iTerm2's sRGB values"),
        Exception(file: "ShellforgeDesign/TerminalPalette.swift", rule: .colour, line: "static let text = NSColor.labelColor",
                  reason: "a source of the terminal match's palette, resolved into iTerm2's sRGB values"),
        Exception(file: "ShellforgeDesign/TerminalPalette.swift", rule: .colour, line: "static let cursor = NSColor.controlAccentColor",
                  reason: "a source of the terminal match's palette, resolved into iTerm2's sRGB values"),
        Exception(file: "ShellforgeDesign/TerminalPalette.swift", rule: .colour, line: "static let selection = NSColor.selectedContentBackgroundColor",
                  reason: "a source of the terminal match's palette, resolved into iTerm2's sRGB values"),
        Exception(file: "ShellforgeDesign/TerminalPalette.swift", rule: .colour, line: "static let black = NSColor.underPageBackgroundColor",
                  reason: "a source of the terminal match's palette, resolved into iTerm2's sRGB values"),
        Exception(file: "ShellforgeDesign/TerminalPalette.swift", rule: .colour, line: "static let brightBlack = NSColor.tertiaryLabelColor",
                  reason: "a source of the terminal match's palette, resolved into iTerm2's sRGB values"),
        Exception(file: "ShellforgeDesign/TerminalPalette.swift", rule: .colour, line: "static let white = NSColor.secondaryLabelColor",
                  reason: "a source of the terminal match's palette, resolved into iTerm2's sRGB values"),
    ]

    /// Beyond AiTerm's rule: SwiftUI's and AppKit's named colours too (`.orange`, `Color.secondary`,
    /// `NSColor.systemBlue`, a colour in a colour modifier or a ternary), none of which is a token —
    /// AiTerm's regex saw only white and black, and the placeholder sidebar's orange got through.
    private static let colourLiteral = try! NSRegularExpression(
        pattern: #"\b(?:NS)?Color\((?:red|white|srgbRed|calibratedRed|deviceRed|calibratedWhite|deviceWhite|genericGamma22White|displayP3Red|hue|srgbHue|calibratedHue|deviceHue):|\b(?:NS)?Color\.(?:white|black)\b|(?<![\w)\]])\.(?:white|black)\b|\b(?:NS)?Color\.(?:red|orange|yellow|green|mint|teal|cyan|blue|indigo|purple|pink|brown|gray|grey|primary|secondary|accentColor)\b|\bNSColor\.(?:system\w+|\w+Color)\b|\b(?:foregroundStyle|foregroundColor|fill|stroke|strokeBorder|background|tint|accentColor)\(\s*\.(?:red|orange|yellow|green|mint|teal|cyan|blue|indigo|purple|pink|brown|gray|grey|primary|secondary)\b|[?:]\s*\.(?:red|orange|yellow|green|mint|teal|cyan|blue|indigo|purple|pink|brown|gray|grey)\b"#)
    private static let derivedColour = try! NSRegularExpression(pattern: #"\bPalette\.[\w.]+\.opacity\("#)
    private static let systemFont = try! NSRegularExpression(
        pattern: #"\.system\(|\bNSFont\.\w*[sS]ystemFont\w*\(|\.font\(\.(?:largeTitle|title2?|title3|headline|subheadline|body|callout|footnote|caption2?)\b"#)
    private static let lengthLiteral = try! NSRegularExpression(
        pattern: #"(?:\.padding\((?:[^()]*,\s*)?|\b(?:spacing|cornerRadius):\s*|\.cornerRadius\(|\.offset\((?:[xy]:\s*)?|\.frame\([^)]*\b(?:width|height|minWidth|idealWidth|maxWidth|minHeight|idealHeight|maxHeight):\s*)-?(?:[1-9]\d*(?:\.\d+)?|0?\.\d*[1-9]\d*)\b"#)
    private static let foreignImport = try! NSRegularExpression(pattern: #"^\s*(?:@testable\s+)?import\s+Shellforge(?:Core|UI)\s*$"#)

    @Test func shellforgeDesignImportsNothingElseInThePackage() throws {
        let violations = try Self.sources().filter { $0.file.hasPrefix("ShellforgeDesign/") }.flatMap { file, lines in
            lines.filter { Self.matches(Self.foreignImport, $0.code) }.map { "\(file):\($0.number): \($0.code)" }
        }
        #expect(violations.isEmpty, "ShellforgeDesign must not import ShellforgeCore or ShellforgeUI: \(violations)")
    }

    @Test func noViewWritesItsOwnColourTextSizeOrLength() throws {
        var used = Set<String>()
        var violations: [String] = []
        for (file, lines) in try Self.sources() {
            for line in lines {
                for rule in Rule.allCases where rule.home != file && Self.matches(rule.pattern, line.code) {
                    if let exception = Self.exceptions.first(where: { $0.file == file && $0.rule == rule && line.code.contains($0.line) }) {
                        used.insert(Self.key(exception))
                    } else {
                        violations.append("\(file):\(line.number): \(rule): \(line.code.trimmingCharacters(in: .whitespaces))")
                    }
                }
            }
        }
        #expect(violations.isEmpty, """
            a colour that is not a Palette member, or a text size or length that is not a Metrics one — \
            name it there (or, for one view's own geometry, in a private static let with its reason): \(violations)
            """)
        let stale = Self.exceptions.map(Self.key).filter { !used.contains($0) }
        #expect(stale.isEmpty, "exceptions that no longer match anything — remove them: \(stale)")
    }

    /// An exception's identity for the stale check: its rule too, so two exceptions for one line —
    /// a font and a length on it — are each proved used, and neither outlives its literal unseen.
    private static func key(_ exception: Exception) -> String { "\(exception.file) [\(exception.rule)]: \(exception.line)" }

    /// The patterns themselves, so a regex that quietly matches nothing cannot pass the scans.
    @Test func thePatternsCatchWhatTheyAreFor() {
        for literal in ["Circle().fill(.white)", "Color.black.opacity(0.4)", "Color(red: 1, green: 0, blue: 0)",
                        ".foregroundStyle(Color.white)", "NSColor.white", "x ? .white : .clear", "Color(white: 0.5)",
                        "NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)", "NSColor(calibratedRed: 0, green: 0, blue: 0, alpha: 1)",
                        "Color(hue: 0.5, saturation: 1, brightness: 1)"] {
            #expect(Self.matches(Self.colourLiteral, literal), "missed \(literal)")
        }
        // SwiftUI's and AppKit's named colours: none of them is AiTerm's, wherever they are written.
        for literal in ["Color.orange", ".foregroundStyle(.orange)", ".fill(.blue)", ".foregroundColor(.red)",
                        ".tint(.green)", ".foregroundStyle(.secondary)", "Color.secondary", "x ? .green : .blue",
                        "NSColor.systemOrange", ".background(.gray)", ".stroke(.purple, lineWidth: 1)"] {
            #expect(Self.matches(Self.colourLiteral, literal), "missed \(literal)")
        }
        for fine in ["Palette.onAccent", "surface.ink", ".whitespaces", "Color(nsColor: .labelColor)", "blackBox",
                     "HelpText(\"x\", tone: .secondary)", "case .secondary:", ".fill(.clear)", "tone == .warning ? Palette.amber : Palette.muted",
                     ".foregroundStyle(Palette.muted)", "Badge(style: .quiet)"] {
            #expect(!Self.matches(Self.colourLiteral, fine), "flagged \(fine)")
        }
        #expect(Self.matches(Self.derivedColour, ".fill(Palette.accent.opacity(0.2))"))
        #expect(!Self.matches(Self.derivedColour, ".fill(Palette.accentPressed)"))
        for literal in [".font(.system(size: 12))", "Font.system(.body)", ".font(.caption)", ".font(.title2)",
                        "NSFont.systemFont(ofSize: 13)", "NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)"] {
            #expect(Self.matches(Self.systemFont, literal), "missed \(literal)")
        }
        for fine in [".font(Typography.body)", "Image(systemName: \"x\")", "Typography.caption.font"] {
            #expect(!Self.matches(Self.systemFont, fine), "flagged \(fine)")
        }
        for literal in [".padding(8)", ".padding(.horizontal, 12)", ".padding([.top, .bottom], 4)", "VStack(spacing: 6)",
                        "RoundedRectangle(cornerRadius: 6)", ".cornerRadius(4)", ".offset(y: -2)", ".offset(x: 0.5)",
                        ".frame(width: 18, height: 18)", ".frame(maxWidth: .infinity, minHeight: 24)"] {
            #expect(Self.matches(Self.lengthLiteral, literal), "missed \(literal)")
        }
        for fine in [".padding(Space.base)", ".padding(.horizontal, scale(Space.gap))", "HStack(spacing: 0)",
                     "RoundedRectangle(cornerRadius: Radius.chip)", ".frame(width: size * 0.2)", ".offset(x: size * fit.dx)",
                     ".frame(maxWidth: .infinity)", ".strokeBorder(Palette.border, lineWidth: 1)", ".frame(width: 0)"] {
            #expect(!Self.matches(Self.lengthLiteral, fine), "flagged \(fine)")
        }
        #expect(Self.code(#"let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\"/>"; Color.white // note"#)
                    .contains("Color.white"), "a // inside a string cut the line")
        #expect(!Self.code("let a = 1 // Color.white").contains("Color.white"), "a comment was scanned")
        #expect(Self.code(##"let svg = #"<svg xmlns="http://www.w3.org/2000/svg"/>"#; Color.white"##)
                    .contains("Color.white"), "a // inside a raw string cut the line")
        #expect(!Self.code(##"let svg = #"a"#  // Color.white"##).contains("Color.white"), "a raw string swallowed a comment")
        #expect(Self.matches(Self.foreignImport, "import ShellforgeCore"))
        #expect(Self.matches(Self.foreignImport, "@testable import ShellforgeUI"))
        #expect(!Self.matches(Self.foreignImport, "import ShellforgeDesign"))
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// `line` with any `//` comment removed. A `//` inside a string literal is text, not a comment:
    /// in a plain string an escaped quote does not end it, and a raw string (`#"…"#`, `##"…"##`)
    /// ends only at a quote followed by as many `#` as opened it. Multi-line strings and `/* */`
    /// blocks are not in the scanned sources, so they are not modelled.
    static func code(_ line: String) -> String {
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "/", i + 1 < chars.count, chars[i + 1] == "/" { return String(chars[..<i]) }
            if ch == "#" || ch == "\"" {
                var hashes = 0
                while i + hashes < chars.count, chars[i + hashes] == "#" { hashes += 1 }
                guard i + hashes < chars.count, chars[i + hashes] == "\"" else { i += 1; continue }
                i += hashes + 1
                // Inside the string: find its closing quote and the same run of `#`.
                while i < chars.count {
                    if hashes == 0, chars[i] == "\\" { i += 2; continue }
                    if chars[i] == "\"", (0..<hashes).allSatisfy({ i + 1 + $0 < chars.count && chars[i + 1 + $0] == "#" }) {
                        i += hashes + 1
                        break
                    }
                    i += 1
                }
                continue
            }
            i += 1
        }
        return line
    }

    /// Every Swift file the rules hold for, by its path under `Sources`, as numbered lines of code:
    /// all of `ShellforgeDesign` and `ShellforgeUI`.
    private static func sources() throws -> [(file: String, lines: [(number: Int, code: String)])] {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = try ["ShellforgeDesign", "ShellforgeUI"].flatMap { module in
            let enumerator = try #require(FileManager.default.enumerator(atPath: directory.appendingPathComponent(module).path))
            return enumerator.compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") && !$0.hasPrefix("Snapshots/") }
                .map { "\(module)/\($0)" }
        }.sorted()
        #expect(files.contains("ShellforgeDesign/Palette.swift") && files.contains("ShellforgeUI/ShellforgeSidebar.swift"),
                "the scan is not reading ShellforgeDesign and the sidebar's views")
        return try files.map { file in
            let source = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
            let lines = source.components(separatedBy: "\n").enumerated().map { index, line in
                (number: index + 1, code: code(line))
            }
            return (file: file, lines: lines)
        }
    }
}
