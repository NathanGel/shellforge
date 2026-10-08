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
        .target(name: "ShellforgeUI", path: "Sources/ShellforgeUI"),
        .testTarget(name: "ShellforgeCoreTests", dependencies: ["ShellforgeCore"], path: "Tests/ShellforgeCoreTests"),
        .testTarget(name: "ShellforgeUITests", dependencies: ["ShellforgeUI"], path: "Tests/ShellforgeUITests"),
    ],
    swiftLanguageModes: [.v6]
)
