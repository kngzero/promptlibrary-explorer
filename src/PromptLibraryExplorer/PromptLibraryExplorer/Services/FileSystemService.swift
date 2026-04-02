import AppKit
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
        let keys: [URLResourceKey] = [.isDirectoryKey, .nameKey]
        let contents = try fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )

        return contents.compactMap { itemURL in
            guard let values = try? itemURL.resourceValues(forKeys: Set(keys)),
                  let isDir = values.isDirectory
            else { return nil }

            return FileEntry(url: itemURL, isDirectory: isDir, children: isDir ? [] : nil)
        }
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
        try fm.moveItem(at: sourceURL, to: targetURL)
        return targetURL
    }

    /// Moves a file from source to destination directory. Returns the final destination URL.
    @discardableResult
    static func moveFile(from source: URL, to destinationDir: URL) throws -> URL {
        let destURL = destinationDir.appendingPathComponent(source.lastPathComponent)
        return try moveEntry(from: source, to: destURL)
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

    /// Gets metadata for a file (name, type, dimensions for images, modified date).
    static func getMetadata(for url: URL) -> FileMetadata {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        let fileType = FileHelpers.describeFileType(ext)

        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let modifiedDate = attrs?[.modificationDate] as? Date
        let fileSize = attrs?[.size] as? Int64

        var width: Int?
        var height: Int?

        if FileHelpers.isImageFile(name) {
            (width, height) = imageDimensions(at: url)
        }

        return FileMetadata(
            fileName: name,
            fileType: fileType,
            width: width,
            height: height,
            modifiedDate: modifiedDate,
            fileSize: fileSize
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

    static func sortFilesIntoDatedSubfolders(directory: URL) throws -> SortResult {
        let entries = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        var result = SortResult(destinationRoot: directory.path)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

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

        result.movedTotal = result.movedImg + result.movedAeo + result.movedPlib
        return result
    }

    static func unsortFilesIntoCurrentFolder(directory: URL, includeSubfolders: Bool) throws -> SortResult {
        let folders = collectUnsortFolders(root: directory, includeSubfolders: includeSubfolders)
        var result = SortResult(destinationRoot: directory.path)

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

        result.movedTotal = result.movedImg + result.movedAeo + result.movedPlib
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
