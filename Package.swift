// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ProperFinder",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "ProperFinderCore"),
        .target(name: "ProperFinderApp", dependencies: ["ProperFinderCore"]),
        .executableTarget(name: "ProperFinder", dependencies: ["ProperFinderApp"]),
        .testTarget(name: "ProperFinderCoreTests", dependencies: ["ProperFinderCore"]),
        .testTarget(name: "ProperFinderAppTests", dependencies: ["ProperFinderApp", "ProperFinderCore"]),
        .testTarget(name: "ProperFinderE2ETests"),
    ],
    swiftLanguageModes: [.v5]
)
