import CryptoKit
import Darwin
import Foundation

// MARK: - Rule evaluation (pure)

enum IngestRuleEngine {
    /// The kind a file name belongs to, or nil for files ingest never handles.
    static func kind(forName name: String) -> IngestFileKinds? {
        if FileHelpers.isImageFile(name) { return .images }
        if FileHelpers.isVideoFile(name) { return .videos }
        if FileHelpers.isAudioFile(name) { return .audio }
        if FileHelpers.isArtOfficialDocumentFile(name) || FileHelpers.isPromptSnapshotFile(name) { return .documents }
        return nil
    }

    /// Why `rules` skip a file, or nil when it's accepted. `relativePath` is the
    /// path inside the source (`sub/name.png`); `size` nil skips the size check
    /// (checked again once the file finished writing).
    static func rejectionReason(name: String, relativePath: String, size: Int64?, rules: IngestRules) -> String? {
        if FolderWatchIgnoreRules.isIgnored(relativePath) { return "hidden or temporary file" }
        guard let kind = kind(forName: name) else { return "unsupported file type" }
        guard rules.kinds.contains(kind) else { return "file type not selected" }
        for pattern in rules.ignorePatterns.map({ $0.trimmingCharacters(in: .whitespaces) }) where !pattern.isEmpty {
            if matchesGlob(pattern, name) || matchesGlob(pattern, relativePath) {
                return "matches ignore pattern \u{201C}\(pattern)\u{201D}"
            }
        }
        if let size, rules.minimumSizeBytes > 0, size < rules.minimumSizeBytes {
            return "smaller than the minimum size"
        }
        return nil
    }

    /// Case-insensitive shell glob (`*.tmp`, `ComfyUI_temp_*`, `preview/*`).
    static func matchesGlob(_ pattern: String, _ text: String) -> Bool {
        fnmatch(pattern, text, FNM_CASEFOLD) == 0
    }

    /// `yyyy/MM-dd` + a date → `2026/09-27`. Each level is a date format; levels
    /// that render empty are dropped and path characters are sanitized.
    static func datedSubfolderPath(template: String, date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        let levels = template.split(separator: "/", omittingEmptySubsequences: true)
        let rendered = levels.compactMap { level -> String? in
            formatter.dateFormat = String(level).trimmingCharacters(in: .whitespaces)
            let value = RenameTemplateService.sanitize(formatter.string(from: date))
            return value.isEmpty ? nil : value
        }
        return rendered.joined(separator: "/")
    }

    /// Where Copy / Move put a file (nil for Leave in Place or without a destination).
    static func destinationFolder(rules: IngestRules, libraryRoot: URL?, date: Date, timeZone: TimeZone = .current) -> URL? {
        guard rules.action != .leaveInPlace else { return nil }
        let base: URL
        if let path = rules.destinationPath, !path.isEmpty {
            base = URL(fileURLWithPath: path, isDirectory: true)
        } else if let libraryRoot {
            base = libraryRoot
        } else {
            return nil
        }
        guard rules.usesDatedSubfolders else { return base.standardizedFileURL }
        let template = rules.datedSubfolderTemplate.trimmingCharacters(in: .whitespaces)
        let sub = datedSubfolderPath(template: template.isEmpty ? IngestRules.defaultDatedTemplate : template, date: date, timeZone: timeZone)
        return (sub.isEmpty ? base : base.appendingPathComponent(sub, isDirectory: true)).standardizedFileURL
    }

    /// The new file name from the rename template, or nil to keep the name.
    static func renamedFileName(template: String, context: RenameTemplateContext) -> String? {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let name = RenameTemplateService.render(template: trimmed, context: context)
        return name == context.url.lastPathComponent ? nil : name
    }

    /// Fixed tags plus (optionally) the cleaned model name, de-duplicated
    /// case-insensitively, in order.
    static func tagNames(rules: IngestRules, model: String?) -> [String] {
        var names = rules.fixedTags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if rules.tagWithModelName, let model = cleanModelName(model) { names.append(model) }
        var seen = Set<String>()
        return names.filter { seen.insert($0.lowercased()).inserted }
    }

    /// "models/sd_xl_base_1.0.safetensors" → "sd_xl_base_1.0"; nil for empty / "N/A".
    static func cleanModelName(_ model: String?) -> String? {
        guard var name = model?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              name.caseInsensitiveCompare("N/A") != .orderedSame
        else { return nil }
        if let slash = name.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
            name = String(name[name.index(after: slash)...])
        }
        for ext in [".safetensors", ".ckpt", ".pt", ".pth", ".bin", ".gguf", ".sft"] where name.lowercased().hasSuffix(ext) {
            name = String(name.dropLast(ext.count))
            break
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Splits a comma-separated field ("ComfyUI, draft") into trimmed values.
    static func list(from text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Path of `url` inside `sourcePath` (the file name when not inside).
    static func relativePath(of path: String, inSource sourcePath: String) -> String {
        let prefix = sourcePath.hasSuffix("/") ? sourcePath : sourcePath + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : (path as NSString).lastPathComponent
    }

    /// True when `path` is inside the source per its subfolder setting.
    static func isWithinSource(_ path: String, source: IngestSource) -> Bool {
        let root = FolderEventCoalescer.trimmed(source.path)
        guard path.hasPrefix(root + "/") else { return false }
        if source.includeSubfolders { return true }
        return (path as NSString).deletingLastPathComponent == root
    }

    /// When a file arrived in its folder: date added (set by moves and downloads),
    /// else creation, else modification date.
    static func arrivalDate(of url: URL) -> Date? {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        let values = try? fresh.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey, .contentModificationDateKey])
        return values?.addedToDirectoryDate ?? values?.creationDate ?? values?.contentModificationDate
    }

    /// A file counts as new when it arrived after `since` (with a little slack for
    /// file systems that store coarse timestamps).
    static func isNewArrival(arrival: Date?, since: Date?, slack: TimeInterval = 2) -> Bool {
        guard let since else { return true }
        guard let arrival else { return false }
        return arrival.timeIntervalSince(since) > -slack
    }
}

// MARK: - Execution (file operations; never overwrites, never deletes)

/// One file to ingest, fully resolved.
struct IngestPlan: Sendable, Equatable {
    var source: URL
    var action: IngestAction
    /// Copy / Move destination (nil for Leave in Place).
    var destinationFolder: URL?
    /// Rendered rename, nil to keep the name.
    var targetName: String?
}

enum IngestExecution: Equatable, Sendable {
    /// Left in place under its own name.
    case surfaced(URL)
    case renamedInPlace(from: URL, to: URL)
    case copied(from: URL, to: URL)
    case moved(from: URL, to: URL)
    /// An identical file already exists in the destination: nothing was copied or
    /// moved, and the source was left where it is.
    case duplicate(source: URL, existing: URL)
    case failed(source: URL, message: String)

    /// Where the file the Inbox should show is now.
    var finalURL: URL? {
        switch self {
        case let .surfaced(url): return url
        case let .renamedInPlace(_, to), let .copied(_, to), let .moved(_, to): return to
        case let .duplicate(_, existing): return existing
        case .failed: return nil
        }
    }

    var sourceURL: URL {
        switch self {
        case let .surfaced(url): return url
        case let .renamedInPlace(from, _), let .copied(from, _), let .moved(from, _): return from
        case let .duplicate(source, _), let .failed(source, _): return source
        }
    }

    var outcomeKind: IngestOutcomeKind? {
        switch self {
        case .surfaced: return .surfaced
        case .renamedInPlace: return .renamed
        case .copied: return .copied
        case .moved: return .moved
        case .duplicate: return .duplicate
        case .failed: return nil
        }
    }
}

/// Finds exact duplicates (same size, then same SHA-256) under a destination
/// folder. Built lazily once per batch; files added by the batch are registered.
final class IngestDuplicateIndex {
    let root: URL
    private var pathsBySize: [Int64: [String]]?
    private var hashes: [String: String] = [:]

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// An existing file under the root with the same bytes as `url` (never `url` itself).
    func duplicate(of url: URL, size: Int64) -> URL? {
        let candidates = (index()[size] ?? []).filter { $0 != url.standardizedFileURL.path }
        guard !candidates.isEmpty, let hash = hash(of: url.standardizedFileURL.path) else { return nil }
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
            if self.hash(of: candidate) == hash { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }

    func register(_ url: URL, size: Int64) {
        _ = index()
        pathsBySize?[size, default: []].append(url.standardizedFileURL.path)
    }

    private func hash(of path: String) -> String? {
        if let cached = hashes[path] { return cached }
        guard let digest = Self.sha256(of: URL(fileURLWithPath: path)) else { return nil }
        hashes[path] = digest
        return digest
    }

    private func index() -> [Int64: [String]] {
        if let pathsBySize { return pathsBySize }
        var result: [Int64: [String]] = [:]
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        if let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                result[Int64(values.fileSize ?? 0), default: []].append(url.standardizedFileURL.path)
            }
        }
        pathsBySize = result
        return result
    }

    /// Streaming SHA-256 (large videos never load whole).
    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            // `read(upToCount:)` returns nil (or empty data) at the end of the file.
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum IngestExecutor {
    /// Performs `plan`. Copies and moves never overwrite (a taken name gets
    /// " 2", " 3"…); an exact duplicate in the destination skips the copy / move
    /// and links the existing file; nothing is ever deleted.
    static func execute(_ plan: IngestPlan, duplicates: IngestDuplicateIndex?) -> IngestExecution {
        let fm = FileManager.default
        let source = plan.source.standardizedFileURL
        guard fm.fileExists(atPath: source.path) else {
            return .failed(source: source, message: "The file is no longer there")
        }

        switch plan.action {
        case .leaveInPlace:
            guard let name = plan.targetName, name != source.lastPathComponent else { return .surfaced(source) }
            let target = FileSystemService.nonConflictingURL(for: source.deletingLastPathComponent().appendingPathComponent(name))
            guard !fm.fileExists(atPath: target.path) else {
                return .failed(source: source, message: "No free name for \u{201C}\(name)\u{201D}")
            }
            do {
                try fm.moveItem(at: source, to: target)
                return .renamedInPlace(from: source, to: target.standardizedFileURL)
            } catch {
                return .failed(source: source, message: error.localizedDescription)
            }

        case .copy, .move:
            guard let folder = plan.destinationFolder?.standardizedFileURL else {
                return .failed(source: source, message: "No destination folder (open a library or choose one in Settings ▸ Ingest)")
            }
            let size = (try? fm.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value ?? 0
            if let existing = duplicates?.duplicate(of: source, size: size) {
                return .duplicate(source: source, existing: existing.standardizedFileURL)
            }
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                return .failed(source: source, message: "Couldn't create the destination folder: \(error.localizedDescription)")
            }
            let proposed = folder.appendingPathComponent(plan.targetName ?? source.lastPathComponent)
            if proposed.standardizedFileURL.path == source.path { return .surfaced(source) }
            let target = FileSystemService.nonConflictingURL(for: proposed).standardizedFileURL
            guard !fm.fileExists(atPath: target.path) else {
                return .failed(source: source, message: "No free name in the destination")
            }
            do {
                // Both refuse to replace an existing item, so nothing is overwritten.
                if plan.action == .copy {
                    try fm.copyItem(at: source, to: target)
                    duplicates?.register(target, size: size)
                    return .copied(from: source, to: target)
                } else {
                    try fm.moveItem(at: source, to: target)
                    duplicates?.register(target, size: size)
                    return .moved(from: source, to: target)
                }
            } catch {
                return .failed(source: source, message: error.localizedDescription)
            }
        }
    }
}
