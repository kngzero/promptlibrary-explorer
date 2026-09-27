import AppIntents
import Foundation


// Shortcuts actions. They run inside the app (launched in the background when
// needed) and call `PromptLibraryAutomation`. Registration needs the bundle's
// Contents/Resources/Metadata.appintents, which scripts/package_app.sh generates
// with Xcode's appintentsmetadataprocessor (SwiftPM doesn't run it) from the
// .swiftconstvalues file the release build emits (Package.swift).

// MARK: - Options

struct CollectionNameOptions: DynamicOptionsProvider {
    func results() async throws -> [String] {
        await MainActor.run { PromptLibraryAutomation.collectionNames }
    }
}

struct ExportPresetNameOptions: DynamicOptionsProvider {
    func results() async throws -> [String] {
        await MainActor.run { PromptLibraryAutomation.presetNames }
    }
}

// MARK: - Search Library

struct SearchLibraryIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Library"
    static let description = IntentDescription(
        "Searches the prompts, file names and generation parameters of every indexed PromptLibrary library and returns the matching files."
    )

    @Parameter(title: "Search For")
    var query: String

    @Parameter(title: "Limit", default: 50, inclusiveRange: (1, 500))
    var limit: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Search library for \(\.$query)") {
            \.$limit
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let urls = await PromptLibraryAutomation.search(query, limit: limit)
        return .result(value: urls.map { IntentFile(fileURL: $0, filename: $0.lastPathComponent) })
    }
}

// MARK: - Add Files to Collection

struct AddFilesToCollectionIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Files to Collection"
    static let description = IntentDescription(
        "Adds files to a PromptLibrary collection. Collections only reference files; nothing is moved or copied."
    )

    @Parameter(title: "Files")
    var files: [IntentFile]

    @Parameter(title: "Collection", optionsProvider: CollectionNameOptions())
    var collection: String

    @Parameter(title: "Create If Missing", default: true)
    var createIfMissing: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$files) to \(\.$collection)") {
            \.$createIfMissing
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let urls = files.compactMap(\.fileURL)
        let result = try PromptLibraryAutomation.addFiles(urls, toCollectionNamed: collection, createIfMissing: createIfMissing)
        return .result(
            value: result.added,
            dialog: "Added \(result.added) file\(result.added == 1 ? "" : "s") to \u{201C}\(result.name)\u{201D}."
        )
    }
}

// MARK: - Export with Preset

struct ExportWithPresetIntent: AppIntent {
    static let title: LocalizedStringResource = "Export with Preset"
    static let description = IntentDescription(
        "Exports copies of files with one of your export presets (format, size, metadata, names, watermark). Originals are never changed; existing files are never replaced."
    )

    @Parameter(title: "Files")
    var files: [IntentFile]

    @Parameter(title: "Preset", optionsProvider: ExportPresetNameOptions())
    var preset: String

    @Parameter(title: "Destination Folder")
    var destination: IntentFile?

    static var parameterSummary: some ParameterSummary {
        Summary("Export \(\.$files) with \(\.$preset)") {
            \.$destination
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        guard let chosen = PromptLibraryAutomation.preset(named: preset) else {
            throw PromptLibraryAutomation.Failure.unknownPreset(preset)
        }
        let written = try await PromptLibraryAutomation.export(
            files.compactMap(\.fileURL), preset: chosen, destination: destination?.fileURL
        )
        return .result(value: written.map { IntentFile(fileURL: $0, filename: $0.lastPathComponent) })
    }
}

// MARK: - Strip AI Metadata

struct StripAIMetadataIntent: AppIntent {
    static let title: LocalizedStringResource = "Strip AI Metadata"
    static let description = IntentDescription(
        "Exports copies with prompts, workflows and generation parameters removed (the Export for Sharing preset). Originals are never changed."
    )

    @Parameter(title: "Files")
    var files: [IntentFile]

    @Parameter(title: "Destination Folder")
    var destination: IntentFile?

    static var parameterSummary: some ParameterSummary {
        Summary("Strip AI metadata from \(\.$files)") {
            \.$destination
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let written = try await PromptLibraryAutomation.stripAIMetadata(
            files.compactMap(\.fileURL), destination: destination?.fileURL
        )
        return .result(value: written.map { IntentFile(fileURL: $0, filename: $0.lastPathComponent) })
    }
}

// MARK: - Open Folder in PromptLibrary

struct OpenFolderInPromptLibraryIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Folder in PromptLibrary"
    static let description = IntentDescription(
        "Opens a folder as the library root in PromptLibrary Explorer (a file opens its folder with the file selected)."
    )
    static let openAppWhenRun = true

    @Parameter(title: "Folder")
    var folder: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$folder) in PromptLibrary")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let url = folder.fileURL else { throw PromptLibraryAutomation.Failure.noFiles }
        try await PromptLibraryAutomation.open(url)
        return .result()
    }
}

// MARK: - Get Prompt of File

struct GetPromptOfFileIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Prompt of File"
    static let description = IntentDescription(
        "Returns the positive prompt embedded in an image (A1111, ComfyUI, NovelAI…), a .plib / .aoe snapshot, or an audio file. Empty when there is none."
    )

    @Parameter(title: "File")
    var file: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Get the prompt of \(\.$file)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let url = file.fileURL else { throw PromptLibraryAutomation.Failure.noFiles }
        return .result(value: await PromptLibraryAutomation.prompt(of: url))
    }
}

// MARK: - App Shortcuts

struct PromptLibraryShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SearchLibraryIntent(),
            phrases: [
                "Search \(.applicationName)",
                "Search my prompts in \(.applicationName)",
            ],
            shortTitle: "Search Library",
            systemImageName: "text.magnifyingglass"
        )
        AppShortcut(
            intent: GetPromptOfFileIntent(),
            phrases: ["Get the prompt of a file with \(.applicationName)"],
            shortTitle: "Get Prompt",
            systemImageName: "text.quote"
        )
        AppShortcut(
            intent: StripAIMetadataIntent(),
            phrases: ["Strip AI metadata with \(.applicationName)"],
            shortTitle: "Strip AI Metadata",
            systemImageName: "eye.slash"
        )
        AppShortcut(
            intent: ExportWithPresetIntent(),
            phrases: ["Export with a preset in \(.applicationName)"],
            shortTitle: "Export with Preset",
            systemImageName: "square.and.arrow.up.on.square"
        )
        AppShortcut(
            intent: AddFilesToCollectionIntent(),
            phrases: ["Add files to a \(.applicationName) collection"],
            shortTitle: "Add to Collection",
            systemImageName: "rectangle.stack.badge.plus"
        )
        AppShortcut(
            intent: OpenFolderInPromptLibraryIntent(),
            phrases: ["Open a folder in \(.applicationName)"],
            shortTitle: "Open Folder",
            systemImageName: "folder"
        )
    }
}
