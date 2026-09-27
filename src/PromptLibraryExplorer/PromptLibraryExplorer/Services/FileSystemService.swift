import AppKit
import AVFoundation
import Foundation

enum FileSystemService {
    private static let fm = FileManager.default

    enum FileOperationError: LocalizedError {
        case trashDestinationUnavailable

        var errorDescription: String? {
            switch self {
            case .trashDestinationUnavailable:
                return "The item was moved to Trash, but its trash location could not be resolved."
            }
        }
    }

    // MARK: - Directory Reading

    /// Reads the contents of a directory (non-recursive).
    static func readDirectory(at url: URL) throws -> [FileEntry] {
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .nameKey, .contentModificationDateKey, .creationDateKey, .fileSizeKey,
            .labelNumberKey, .tagNamesKey,
        ]
        let contents = try fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )

        return contents.compactMap { itemURL in
            guard let values = try? itemURL.resourceValues(forKeys: Set(keys)),
                  let isDir = values.isDirectory
            else { return nil }

            var entry = FileEntry(
                url: itemURL,
                isDirectory: isDir,
                children: isDir ? [] : nil,
                modifiedDate: values.contentModificationDate,
                creationDate: values.creationDate,
                fileSize: isDir ? nil : values.fileSize.map(Int64.init),
                labelNumber: values.labelNumber
            )
            // For the Finder tag mirror (CurationController).
            entry.tagNames = values.tagNames ?? []
            // Online-only cloud placeholders (one lstat; never reads contents).
            entry.isCloudOnly = CloudFileStatus.isCloudOnly(path: itemURL.path, isDirectory: isDir)
            return entry
        }
    }

    // MARK: - Finder Labels

    /// The item's Finder colour label read fresh from disk (0 = none).
    static func labelNumber(at url: URL) -> Int {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        return (try? fresh.resourceValues(forKeys: [.labelNumberKey]))?.labelNumber ?? 0
    }

    /// Sets the item's Finder colour label (0 clears it). This is Finder's own
    /// label, so Finder and other apps see it too.
    static func setLabelNumber(_ labelNumber: Int, at url: URL) throws {
        var target = url
        var values = URLResourceValues()
        values.labelNumber = max(0, min(7, labelNumber))
        try target.setResourceValues(values)
        target.removeAllCachedResourceValues()
    }

    /// Reads subdirectories (one level) from a directory, sorted by name.
    static func readSubdirectories(at url: URL) throws -> [FileEntry] {
        let all = try readDirectory(at: url)
        return all
            .filter(\.isDirectory)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Recursively builds a folder tree from a root URL (directories only, 2 levels deep for perf).
    static func buildFolderTree(root: URL, depth: Int = 2) throws -> [FileEntry] {
        guard depth > 0 else { return [] }
        let dirs = try readSubdirectories(at: root)
        return dirs.map { entry in
            var e = entry
            if let children = try? buildFolderTree(root: entry.url, depth: depth - 1) {
                e.children = children
            }
            return e
        }
    }

    // MARK: - File Operations

    /// Moves a file or folder from source to an exact destination URL.
    @discardableResult
    static func moveEntry(from source: URL, to destinationURL: URL) throws -> URL {
        let sourceURL = source.standardizedFileURL
        let targetURL = destinationURL.standardizedFileURL
        if sourceURL == targetURL { return targetURL }
        // Same file reached through a different path (symlink, case variant): nothing to move
        // unless the name itself changes (e.g. a case-only rename, which moveItem handles).
        if sourceURL.lastPathComponent == targetURL.lastPathComponent,
           isSameFile(sourceURL, targetURL) {
            return sourceURL
        }
        try fm.moveItem(at: sourceURL, to: targetURL)
        return targetURL
    }

    /// Moves a file from source to destination directory. Returns the final destination URL.
    /// Throws if the name is already taken — callers that need a collision policy
    /// should use `moveFile(from:to:onDuplicate:)`.
    @discardableResult
    static func moveFile(from source: URL, to destinationDir: URL) throws -> URL {
        let destURL = destinationDir.appendingPathComponent(source.lastPathComponent)
        return try moveEntry(from: source, to: destURL)
    }

    enum MoveResolution {
        case moved(URL)
        case skipped
    }

    /// Moves a file into a directory, resolving a name collision per `policy`.
    static func moveFile(
        from source: URL,
        to destinationDir: URL,
        onDuplicate policy: DuplicateNamePolicy
    ) throws -> MoveResolution {
        try moveFileReportingReplacement(from: source, to: destinationDir, onDuplicate: policy).resolution
    }

    /// Like `moveFile(from:to:onDuplicate:)`, but also reports where a replaced
    /// item went: with `.replace`, `replacedTrashURL` is the Trash location of
    /// the item that used to be at the destination (the `.moved` URL).
    static func moveFileReportingReplacement(
        from source: URL,
        to destinationDir: URL,
        onDuplicate policy: DuplicateNamePolicy
    ) throws -> (resolution: MoveResolution, replacedTrashURL: URL?) {
        let sourceURL = source.standardizedFileURL
        let proposedURL = destinationDir
            .appendingPathComponent(sourceURL.lastPathComponent)
            .standardizedFileURL

        // No collision (or the file is already exactly where it is going).
        guard fm.fileExists(atPath: proposedURL.path), proposedURL != sourceURL else {
            return (.moved(try moveEntry(from: sourceURL, to: proposedURL)), nil)
        }

        // The "existing" destination is the source itself, reached via a symlinked or
        // case-variant path. Treat as a no-op rather than trashing the file we are moving.
        if isSameFile(sourceURL, proposedURL) {
            return (.moved(sourceURL), nil)
        }

        switch policy {
        case .keepBoth:
            return (.moved(try moveEntry(from: sourceURL, to: nonConflictingURL(for: proposedURL))), nil)
        case .skip:
            return (.skipped, nil)
        case .replace:
            // Trash rather than delete, so a mistaken replace is still recoverable.
            let trashedURL = try moveToTrash(at: proposedURL)
            do {
                return (.moved(try moveEntry(from: sourceURL, to: proposedURL)), trashedURL)
            } catch {
                // Put the replaced item back so a failed move doesn't lose it to the Trash.
                if !fm.fileExists(atPath: proposedURL.path) {
                    try? fm.moveItem(at: trashedURL, to: proposedURL)
                }
                throw error
            }
        }
    }

    /// True when both URLs refer to the same file system object, resolving symlinks and
    /// case-insensitive path variants.
    static func isSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        let a = lhs.standardizedFileURL.resolvingSymlinksInPath()
        let b = rhs.standardizedFileURL.resolvingSymlinksInPath()
        if a.path == b.path { return true }

        guard let idA = (try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier,
              let idB = (try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier
        else { return false }
        return idA.isEqual(idB)
    }

    /// `sunset.png` -> `sunset 2.png` -> `sunset 3.png`, skipping names already on disk.
    static func nonConflictingURL(for proposed: URL) -> URL {
        guard fm.fileExists(atPath: proposed.path) else { return proposed }

        let parent = proposed.deletingLastPathComponent()
        let ext = proposed.pathExtension
        let base = proposed.deletingPathExtension().lastPathComponent

        for suffix in 2...1000 {
            let name = ext.isEmpty ? "\(base) \(suffix)" : "\(base) \(suffix).\(ext)"
            let candidate = parent.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        // A thousand collisions on one name is pathological; let the move report it.
        return proposed
    }

    /// Renames a file or folder. Returns the new URL.
    @discardableResult
    static func rename(at url: URL, to newName: String) throws -> URL {
        let parent = url.deletingLastPathComponent()
        let destURL = parent.appendingPathComponent(newName)
        return try moveEntry(from: url, to: destURL)
    }

    /// Deletes a file or directory permanently.
    static func deleteEntry(at url: URL) throws {
        try fm.removeItem(at: url)
    }

    /// Moves a file or directory to the system Trash and returns its trash location.
    @discardableResult
    static func moveToTrash(at url: URL) throws -> URL {
        var trashedURL: NSURL?
        try fm.trashItem(at: url, resultingItemURL: &trashedURL)

        guard let trashedURL = trashedURL as URL? else {
            throw FileOperationError.trashDestinationUnavailable
        }

        return trashedURL.standardizedFileURL
    }

    /// Creates a new folder inside a parent directory. Returns the new folder URL.
    @discardableResult
    static func createFolder(in parent: URL, named name: String) throws -> URL {
        let folderURL = parent.appendingPathComponent(name)
        try fm.createDirectory(at: folderURL, withIntermediateDirectories: false)
        return folderURL
    }

    /// Reveals a file in Finder.
    static func revealInFinder(url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Opens a file with a specific application.
    static func openFile(url: URL, withApplication appURL: URL) {
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    /// Returns the list of application URLs that can open a given file.
    static func applicationsForFile(url: URL) -> [URL] {
        NSWorkspace.shared.urlsForApplications(toOpen: url)
    }

    // MARK: - File Metadata

    /// Gets metadata for a file (name, type, image dimensions, modified date).
    /// Video dimensions/duration require async AVFoundation loading, so they are only
    /// filled in by `getMetadataAsync(for:)`.
    static func getMetadata(for url: URL) -> FileMetadata {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        let fileType = FileHelpers.describeFileType(ext)

        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let modifiedDate = attrs?[.modificationDate] as? Date
        let fileSize = attrs?[.size] as? Int64

        var width: Int?
        var height: Int?
        let duration: TimeInterval? = nil

        if FileHelpers.isImageFile(name) {
            (width, height) = imageDimensions(at: url)
        }

        return FileMetadata(
            fileName: name,
            fileType: fileType,
            width: width,
            height: height,
            duration: duration,
            modifiedDate: modifiedDate,
            fileSize: fileSize
        )
    }

    /// Resolves file metadata off the main thread so selection stays responsive.
    static func getMetadataAsync(for url: URL) async -> FileMetadata {
        let base = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: getMetadata(for: url))
            }
        }

        guard FileHelpers.isVideoFile(url.lastPathComponent) else { return base }

        let video = await videoMetadata(at: url)
        return FileMetadata(
            fileName: base.fileName,
            fileType: base.fileType,
            width: video.width,
            height: video.height,
            duration: video.duration,
            modifiedDate: base.modifiedDate,
            fileSize: base.fileSize
        )
    }

    /// Reads image dimensions without loading the full image into memory.
    static func imageDimensions(at url: URL) -> (width: Int?, height: Int?) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return (nil, nil)
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return (nil, nil)
        }
        let w = properties[kCGImagePropertyPixelWidth] as? Int
        let h = properties[kCGImagePropertyPixelHeight] as? Int
        return (w, h)
    }

    static func videoMetadata(at url: URL) async -> (width: Int?, height: Int?, duration: TimeInterval?) {
        let asset = AVURLAsset(url: url)

        var width: Int?
        var height: Int?

        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let (naturalSize, transform) = try? await track.load(.naturalSize, .preferredTransform)
        {
            let transformedSize = naturalSize.applying(transform)
            width = Int(abs(transformedSize.width).rounded())
            height = Int(abs(transformedSize.height).rounded())
        }

        var duration: TimeInterval?
        if let time = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(time)
            duration = seconds.isFinite && !seconds.isNaN ? seconds : nil
        }

        return (width, height, duration)
    }

    // MARK: - Favorite Directories

    static var desktopURL: URL? {
        fm.urls(for: .desktopDirectory, in: .userDomainMask).first
    }

    static var documentsURL: URL? {
        fm.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    static var picturesURL: URL? {
        fm.urls(for: .picturesDirectory, in: .userDomainMask).first
    }

    // MARK: - Folder Dialog

    @MainActor
    static func openFolderDialog(
        title: String = "Select a Folder",
        prompt: String = "Open",
        directoryURL: URL? = nil
    ) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = directoryURL
        panel.title = title
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: - File Sorting (port of Rust sort_files_into_dated_subfolders)

    struct SortResult {
        var movedTotal: Int = 0
        var movedImg: Int = 0
        var movedAeo: Int = 0
        var movedPlib: Int = 0
        var destinationRoot: String = ""
    }

    /// Thrown when a sort/unsort stops partway; carries what was already moved.
    struct PartialSortError: LocalizedError {
        let partialResult: SortResult
        let underlying: Error

        var errorDescription: String? {
            let moved = partialResult.movedTotal
            let reason = (underlying as? LocalizedError)?.errorDescription ?? underlying.localizedDescription
            return moved > 0
                ? "\(moved) file\(moved == 1 ? "" : "s") moved before the failure. \(reason)"
                : reason
        }
    }

    private static func finalize(_ result: inout SortResult) {
        result.movedTotal = result.movedImg + result.movedAeo + result.movedPlib
    }

    static func sortFilesIntoDatedSubfolders(directory: URL) throws -> SortResult {
        let entries = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        var result = SortResult(destinationRoot: directory.path)
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.timeZone = .current
        dateFormatter.dateFormat = "yyyy-MM-dd"

        do {
            for entry in entries {
                guard let values = try? entry.resourceValues(forKeys: [.isRegularFileKey]),
                      values.isRegularFile == true
                else { continue }

                let ext = entry.pathExtension.lowercased()
                guard let destType = destinationFolderForExtension(ext) else { continue }

                let attrs = try fm.attributesOfItem(atPath: entry.path)
                let createdDate = (attrs[.creationDate] as? Date) ?? (attrs[.modificationDate] as? Date) ?? Date()
                let dateSegment = dateFormatter.string(from: createdDate)

                let destDir = directory.appendingPathComponent(dateSegment).appendingPathComponent(destType)
                try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

                let destPath = nextAvailablePath(destDir.appendingPathComponent(entry.lastPathComponent))
                try fm.moveItem(at: entry, to: destPath)

                switch destType {
                case "img": result.movedImg += 1
                case "aeo": result.movedAeo += 1
                case "plib": result.movedPlib += 1
                default: break
                }
            }
        } catch {
            finalize(&result)
            throw PartialSortError(partialResult: result, underlying: error)
        }

        finalize(&result)
        return result
    }

    static func unsortFilesIntoCurrentFolder(directory: URL, includeSubfolders: Bool) throws -> SortResult {
        let folders = collectUnsortFolders(root: directory, includeSubfolders: includeSubfolders)
        var result = SortResult(destinationRoot: directory.path)

        do {
            for folder in folders {
                let entries = try fm.contentsOfDirectory(
                    at: folder,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )

                for entry in entries {
                    guard let values = try? entry.resourceValues(forKeys: [.isRegularFileKey]),
                          values.isRegularFile == true
                    else { continue }

                    let ext = entry.pathExtension.lowercased()
                    guard let destType = destinationFolderForExtension(ext) else { continue }

                    let destPath = nextAvailablePath(directory.appendingPathComponent(entry.lastPathComponent))
                    try fm.moveItem(at: entry, to: destPath)

                    switch destType {
                    case "img": result.movedImg += 1
                    case "aeo": result.movedAeo += 1
                    case "plib": result.movedPlib += 1
                    default: break
                    }
                }
            }
        } catch {
            finalize(&result)
            throw PartialSortError(partialResult: result, underlying: error)
        }

        finalize(&result)
        return result
    }

    // MARK: - Private Helpers

    private static func destinationFolderForExtension(_ ext: String) -> String? {
        switch ext.lowercased() {
        case "aoe": return "aeo"
        case "plib": return "plib"
        case _ where FileHelpers.imageExtensions.contains(ext.lowercased()): return "img"
        default: return nil
        }
    }

    private static func nextAvailablePath(_ url: URL) -> URL {
        guard fm.fileExists(atPath: url.path) else { return url }

        let parent = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension

        for suffix in 1... {
            let name = ext.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(ext)"
            let candidate = parent.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return url // unreachable
    }

    private static let unsortFolderNames: Set<String> = ["img", "aeo", "aoe", "plib"]

    private static func collectUnsortFolders(root: URL, includeSubfolders: Bool) -> [URL] {
        if !includeSubfolders {
            return unsortFolderNames.compactMap { name in
                let candidate = root.appendingPathComponent(name)
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: candidate.path, isDirectory: &isDir) && isDir.boolValue
                    ? candidate : nil
            }
        }

        var folders: [URL] = []
        var stack = [root]

        while let dir = stack.popLast() {
            guard let entries = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for entry in entries {
                guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey]),
                      values.isDirectory == true
                else { continue }

                if unsortFolderNames.contains(entry.lastPathComponent.lowercased()) {
                    folders.append(entry)
                } else {
                    stack.append(entry)
                }
            }
        }

        return folders
    }
}
