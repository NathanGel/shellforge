// swift-tools-version:6.0
import PackageDescription

// Shellforge's own code, kept out of iTerm2's sources so upstream merges stay small. It builds and
// tests with swiftly's toolchain (`scripts/swift.sh`), no Xcode needed, and targets iTerm2's own
// deployment target so the app can link it.
let package = Package(
    name: "Shellforge",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ShellforgeCore", targets: ["ShellforgeCore"]),
        .library(name: "ShellforgeUI", targets: ["ShellforgeUI"]),
    ],
    targets: [
        .target(name: "ShellforgeCore", path: "Sources/ShellforgeCore"),
        // AiTerm's design system: depends on nothing but SwiftUI and AppKit (DesignRulesTests).
        .target(name: "ShellforgeDesign", path: "Sources/ShellforgeDesign", exclude: ["README.md"]),
        .target(name: "ShellforgeUI", dependencies: ["ShellforgeCore", "ShellforgeDesign"], path: "Sources/ShellforgeUI"),
        // Fakes and helpers the test targets share; test targets cannot share a source file.
        .target(name: "ShellforgeTestSupport", dependencies: ["ShellforgeCore"], path: "Tests/ShellforgeTestSupport"),
        .testTarget(name: "ShellforgeCoreTests", dependencies: ["ShellforgeCore", "ShellforgeTestSupport"], path: "Tests/ShellforgeCoreTests"),
        .testTarget(name: "ShellforgeDesignTests", dependencies: ["ShellforgeDesign"], path: "Tests/ShellforgeDesignTests"),
        .testTarget(name: "ShellforgeUITests", dependencies: ["ShellforgeUI", "ShellforgeCore", "ShellforgeDesign", "ShellforgeTestSupport"], path: "Tests/ShellforgeUITests"),
    ],
    swiftLanguageModes: [.v6]
)
