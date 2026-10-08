// swift-tools-version:6.4
import PackageDescription

// Shellforge's own code, kept out of iTerm2's sources so upstream merges stay small. It builds and
// tests with swiftly's toolchain (`scripts/swift.sh`), no Xcode needed, and targets iTerm2's own
// deployment target so the app can link it.
let package = Package(
    name: "Shellforge",
    platforms: [.macOS(.v13)],
    products: [.library(name: "ShellforgeCore", targets: ["ShellforgeCore"])],
    targets: [
        .target(name: "ShellforgeCore", path: "Sources/ShellforgeCore"),
        .testTarget(name: "ShellforgeCoreTests", dependencies: ["ShellforgeCore"], path: "Tests/ShellforgeCoreTests"),
    ],
    swiftLanguageModes: [.v6]
)
