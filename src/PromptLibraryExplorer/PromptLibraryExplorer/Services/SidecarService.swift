import Foundation

/// Remembers which sidecars were already imported or written (path → modification time),
/// so a sidecar is only imported again after something else changed it.
final class SidecarSyncState: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var seen: [String: Double]
    private var dirty = false

    init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([String: Double].self, from: data) {
            seen = decoded
        } else {
            seen = [:]
        }
    }

    static var defaultURL: URL {
        CollectionServiceStorage.directoryURL.appendingPathComponent("xmp-sidecar-state.json")
    }

    static func modificationStamp(of url: URL) -> Double? {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        return (try? fresh.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970
    }

    func isUnchanged(_ sidecar: URL) -> Bool {
        guard let stamp = Self.modificationStamp(of: sidecar) else { return false }
        lock.lock()
        defer { lock.unlock() }
        return seen[sidecar.path] == stamp
    }

    func record(_ sidecar: URL) {
        guard let stamp = Self.modificationStamp(of: sidecar) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard seen[sidecar.path] != stamp else { return }
        seen[sidecar.path] = stamp
        dirty = true
    }

    func flush() {
        lock.lock()
        guard dirty else {
            lock.unlock()
            return
        }
        let snapshot = seen
        dirty = false
        lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: url, options: [.atomic])
        }
    }
}

/// Everything the app writes into one file's sidecar.
struct SidecarFileCuration: Sendable {
    var path: String
    var rating: Int
    var flag: FileFlag
    var tagNames: [String]
    var label: FinderLabel
    var prompt: String?
    var negativePrompt: String?

    var values: XMPSidecarValues {
        XMPSidecarValues(
            rating: rating,
            label: XMPSidecarValues.labelName(for: label),
            subjects: tagNames,
            descriptionText: prompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? prompt : nil,
            flag: flag,
            negativePrompt: negativePrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? negativePrompt : nil
        )
    }

    var hasCuration: Bool { rating > 0 || flag != .unflagged || !tagNames.isEmpty || label != .none }
}

enum SidecarWriter {
    /// Writes (or updates in place) the sidecar of one file. Never touches the file itself.
    /// Without `force`, a file with no curation and no sidecar yet gets none. Returns the
    /// sidecar URL when its content changed.
    @discardableResult
    static func write(
        _ curation: SidecarFileCuration,
        force: Bool,
        state: SidecarSyncState?,
        fileManager: FileManager = .default
    ) throws -> URL? {
        let fileURL = URL(fileURLWithPath: curation.path)
        guard SidecarLocator.supportsSidecar(fileURL.lastPathComponent),
              fileManager.fileExists(atPath: fileURL.path)
        else { return nil }
        let sidecar = SidecarLocator.sidecarURL(for: fileURL, fileManager: fileManager)
        let existing = try? Data(contentsOf: sidecar)
        guard existing != nil || force || curation.hasCuration else { return nil }
        // Unchanged values: leave the file (and its mtime / Dropbox) alone.
        if let existing, XMPSidecarCodec.parse(existing).map({ sameValues($0, curation.values) }) == true {
            state?.record(sidecar)
            return nil
        }
        let data = XMPSidecarCodec.render(curation.values, updating: existing)
        try data.write(to: sidecar, options: [.atomic])
        state?.record(sidecar)
        return sidecar
    }

    private static func sameValues(_ lhs: XMPSidecarValues, _ rhs: XMPSidecarValues) -> Bool {
        (lhs.rating ?? 0) == (rhs.rating ?? 0)
            && (lhs.label ?? "") == (rhs.label ?? "")
            && lhs.subjects == rhs.subjects
            && (lhs.descriptionText ?? "") == (rhs.descriptionText ?? "")
            && (lhs.flag ?? .unflagged) == (rhs.flag ?? .unflagged)
            && (lhs.negativePrompt ?? "") == (rhs.negativePrompt ?? "")
    }
}

/// What to bring in from one sidecar: only fields the app has nothing for.
struct SidecarImport: Equatable, Sendable {
    var path: String
    var rating: Int?
    var flag: FileFlag?
    var tagNames: [String]?
    var label: FinderLabel?

    var isEmpty: Bool { rating == nil && flag == nil && tagNames == nil && label == nil }
}

/// The app's values for one file, as the importer compares them.
struct SidecarAppValues: Sendable {
    var rating = 0
    var flag = FileFlag.unflagged
    var tagNames: [String] = []
    var label = FinderLabel.none
}

enum SidecarImporter {
    /// Compares a sidecar with the app's values. The app always wins: only empty fields
    /// are filled; differing values are reported as conflicts (to be logged).
    static func plan(path: String, sidecar: XMPSidecarValues, app: SidecarAppValues) -> (SidecarImport, conflicts: [String]) {
        var result = SidecarImport(path: path)
        var conflicts: [String] = []
        if let rating = sidecar.rating, rating > 0 {
            if app.rating == 0 { result.rating = rating } else if app.rating != rating { conflicts.append("rating") }
        }
        if let flag = sidecar.flag, flag != .unflagged {
            if app.flag == .unflagged { result.flag = flag } else if app.flag != flag { conflicts.append("flag") }
        }
        let keywords = sidecar.subjects.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !keywords.isEmpty {
            if app.tagNames.isEmpty {
                result.tagNames = keywords
            } else if !FinderTagMerge.sameSet(app.tagNames, keywords) {
                conflicts.append("keywords")
            }
        }
        if let label = sidecar.finderLabel, label != .none {
            if app.label == .none { result.label = label } else if app.label != label { conflicts.append("label") }
        }
        return (result, conflicts)
    }

    /// Reads the sidecars of `files` that haven't been seen at their current modification
    /// time and plans their imports. Runs off the main actor.
    static func scan(
        files: [(path: String, app: SidecarAppValues)],
        siblingsByFolder: [String: [String]],
        state: SidecarSyncState
    ) -> [SidecarImport] {
        var imports: [SidecarImport] = []
        for file in files {
            let url = URL(fileURLWithPath: file.path)
            let folder = url.deletingLastPathComponent().path
            guard let sidecar = SidecarLocator.existingSidecar(for: url, siblings: siblingsByFolder[folder]),
                  !state.isUnchanged(sidecar),
                  let data = try? Data(contentsOf: sidecar),
                  let values = XMPSidecarCodec.parse(data)
            else { continue }
            state.record(sidecar)
            let (planned, conflicts) = plan(path: file.path, sidecar: values, app: file.app)
            if !conflicts.isEmpty {
                NSLog("PromptLibraryExplorer: XMP sidecar %@ differs from the app (%@); kept the app's values",
                      sidecar.lastPathComponent, conflicts.joined(separator: ", "))
            }
            if !planned.isEmpty { imports.append(planned) }
        }
        return imports
    }
}
