import Foundation
import Observation

/// Named export presets, persisted as JSON in Application Support
/// (`PromptLibraryExplorer/export-presets.json`). The first launch gets the shipped
/// defaults; the sharing preset is always available even if its row was removed.
@MainActor @Observable
final class ExportPresetStore {
    static let shared = ExportPresetStore()

    private(set) var presets: [ExportPreset]

    @ObservationIgnored private let fileURL: URL

    nonisolated static var defaultFileURL: URL {
        CollectionServiceStorage.directoryURL.appendingPathComponent("export-presets.json")
    }

    init(fileURL: URL = ExportPresetStore.defaultFileURL) {
        self.fileURL = fileURL
        presets = Self.load(from: fileURL) ?? ExportPreset.defaults
    }

    /// Decodes a presets file leniently; nil when missing or unreadable.
    nonisolated static func load(from url: URL) -> [ExportPreset]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    nonisolated static func decode(_ data: Data) -> [ExportPreset]? {
        guard let file = try? JSONDecoder().decode(PresetFile.self, from: data) else { return nil }
        return file.presets
    }

    nonisolated static func encode(_ presets: [ExportPreset]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(PresetFile(version: 1, presets: presets))
    }

    /// On-disk envelope. Each preset decodes on its own, so one bad entry doesn't
    /// lose the rest.
    private struct PresetFile: Codable {
        var version: Int
        var presets: [ExportPreset]

        init(version: Int, presets: [ExportPreset]) {
            self.version = version
            self.presets = presets
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = (try? c.decode(Int.self, forKey: .version)) ?? 1
            var items = try c.nestedUnkeyedContainer(forKey: .presets)
            var decoded: [ExportPreset] = []
            while !items.isAtEnd {
                if let preset = try? items.decode(ExportPreset.self) {
                    decoded.append(preset)
                } else {
                    _ = try? items.decode(DiscardedValue.self)
                }
            }
            presets = decoded
        }

        private struct DiscardedValue: Decodable {}
    }

    private func persist() {
        do {
            let data = try Self.encode(presets)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("ExportPresetStore: couldn't save presets: \(error.localizedDescription)")
        }
    }

    // MARK: Queries

    func preset(id: UUID?) -> ExportPreset? {
        guard let id else { return nil }
        return presets.first(where: { $0.id == id })
    }

    /// The preset behind File ▸ Export for Sharing (the stored copy if it's still there).
    var sharingPreset: ExportPreset {
        preset(id: ExportPreset.sharingID) ?? .sharing
    }

    // MARK: Mutations

    func save(_ preset: ExportPreset) {
        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index] = preset
        } else {
            presets.append(preset)
        }
        persist()
    }

    @discardableResult
    func add(copyOf preset: ExportPreset, name: String? = nil) -> ExportPreset {
        var copy = preset
        copy.id = UUID()
        copy.name = uniqueName(name ?? "\(preset.name) Copy")
        presets.append(copy)
        persist()
        return copy
    }

    func delete(id: UUID) {
        guard id != ExportPreset.sharingID else { return }
        presets.removeAll { $0.id == id }
        persist()
    }

    /// Restores the shipped presets (custom presets are kept).
    func restoreDefaults() {
        for preset in ExportPreset.defaults {
            if let index = presets.firstIndex(where: { $0.id == preset.id }) {
                presets[index] = preset
            } else {
                presets.append(preset)
            }
        }
        persist()
    }

    func uniqueName(_ base: String) -> String {
        let taken = Set(presets.map { $0.name.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }
}
