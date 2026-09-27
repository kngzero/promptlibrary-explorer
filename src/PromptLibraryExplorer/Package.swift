// swift-tools-version: 5.9
 import PackageDescription

// App-extension link flags (Xcode's appex recipe): link app-extension-safe and enter at
// Foundation's NSExtensionMain. See Extensions/README.md for why the extension sources
// have no main.swift / @main.
let extensionLinkerFlags = [
    "-Xlinker", "-application_extension",
    "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain",
]

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
        // MARK: Quick Look app extensions (see Extensions/README.md)
        // SwiftPM can't emit .appex bundles; these build as plain executables that
        // scripts/package_app.sh wraps into PlugIns/PLX*.appex.
        .target(
            name: "PLXQuickLookSupport",
            dependencies: ["ArtOfficialFormats"],
            path: "Extensions/Shared",
            swiftSettings: [.unsafeFlags(["-application-extension"])]
        ),
        .target(
            name: "PLXExtensionEntry",
            path: "Extensions/EntryShim",
            cSettings: [.unsafeFlags(["-fapplication-extension"])]
        ),
        .executableTarget(
            name: "PLXQuickLookPreview",
            dependencies: ["PLXQuickLookSupport", "PLXExtensionEntry"],
            path: "Extensions/PLXQuickLookPreview",
            exclude: ["Info.plist", "PLXQuickLookPreview.entitlements"],
            swiftSettings: [.unsafeFlags(["-application-extension", "-parse-as-library"])],
            linkerSettings: [
                .linkedFramework("QuickLookUI"),
                .unsafeFlags(extensionLinkerFlags)
            ]
        ),
        .executableTarget(
            name: "PLXQuickLookThumbnail",
            dependencies: ["PLXQuickLookSupport", "PLXExtensionEntry"],
            path: "Extensions/PLXQuickLookThumbnail",
            exclude: ["Info.plist", "PLXQuickLookThumbnail.entitlements"],
            swiftSettings: [.unsafeFlags(["-application-extension", "-parse-as-library"])],
            linkerSettings: [
                .linkedFramework("QuickLookThumbnailing"),
                .unsafeFlags(extensionLinkerFlags)
            ]
        ),
        .testTarget(
            name: "PLXQuickLookSupportTests",
            dependencies: ["PLXQuickLookSupport", "ArtOfficialFormats"],
            path: "Tests/PLXQuickLookSupportTests"
        ),
        .testTarget(
            name: "PromptLibraryExplorerTests",
            dependencies: ["PromptLibraryExplorer", "ArtOfficialFormats"],
            path: "Tests/PromptLibraryExplorerTests"
        )
    ]
)
