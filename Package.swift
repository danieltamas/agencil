// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Agencil",
    platforms: [.macOS(.v14)],
    targets: [
        // Everything testable without a UI: collectors, rules, store. Never imports SwiftUI or AppKit.
        .target(name: "AgencilCore"),
        .executableTarget(name: "Agencil", dependencies: ["AgencilCore"]),
        // Installed as `agencil`. Named AgencilCLI because `agencil` collides with `Agencil` on a
        // case-insensitive disk; scripts/bundle.sh renames the binary.
        .executableTarget(name: "AgencilCLI", dependencies: ["AgencilCore"]),
        .testTarget(name: "AgencilCoreTests", dependencies: ["AgencilCore"]),
        .testTarget(name: "AgencilTests", dependencies: ["Agencil"]),
    ]
)
