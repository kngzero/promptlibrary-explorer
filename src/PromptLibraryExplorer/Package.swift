// swift-tools-version: 5.9
 import PackageDescription

let package = Package(
    name: "PromptLibraryExplorer",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ArtOfficialFormats", targets: ["ArtOfficialFormats"])
    ],
    targets: [
        .target(
            name: "ArtOfficialFormats",
            path: "ArtOfficialFormats",
            exclude: ["API.md"],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .executableTarget(
            name: "PromptLibraryExplorer",
            dependencies: ["ArtOfficialFormats"],
            path: "PromptLibraryExplorer"
        ),
        .testTarget(
            name: "PromptLibraryExplorerTests",
            dependencies: ["PromptLibraryExplorer", "ArtOfficialFormats"],
            path: "Tests/PromptLibraryExplorerTests"
        )
    ]
)
