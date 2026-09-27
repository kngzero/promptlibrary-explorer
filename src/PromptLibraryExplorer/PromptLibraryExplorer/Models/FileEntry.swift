import Foundation

/// Represents a file or directory in the file system.
struct FileEntry: Identifiable, Hashable {
    let id: String // absolute path
    let url: URL
    let name: String
    let isDirectory: Bool
    var children: [FileEntry]?
    /// Filled by `FileSystemService.readDirectory`; nil when unknown.
    var modifiedDate: Date?
    var creationDate: Date?
    var fileSize: Int64?
    /// Finder colour label (`URLResourceKey.labelNumberKey`, 0 = none, see
    /// `FinderLabel`); nil when unknown.
    var labelNumber: Int?
    /// Finder tag names (`URLResourceKey.tagNamesKey`, colour labels included) as read
    /// by `FileSystemService.readDirectory`; nil when not read.
    var tagNames: [String]?
    /// Online-only cloud placeholder (dataless File Provider / iCloud file) when the
    /// entry was read; see `CloudFileStatus`. Files only.
    var isCloudOnly = false

    var path: String { url.path }

    init(
        url: URL,
        isDirectory: Bool,
        children: [FileEntry]? = nil,
        modifiedDate: Date? = nil,
        creationDate: Date? = nil,
        fileSize: Int64? = nil,
        labelNumber: Int? = nil
    ) {
        self.id = url.path
        self.url = url
        self.name = url.lastPathComponent
        self.isDirectory = isDirectory
        self.children = children
        self.modifiedDate = modifiedDate
        self.creationDate = creationDate
        self.fileSize = fileSize
        self.labelNumber = labelNumber
    }

    /// Reads a single entry (with dates and size) from disk, or nil when missing.
    static func load(from url: URL) -> FileEntry? {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .contentModificationDateKey, .creationDateKey, .fileSizeKey, .labelNumberKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
              let isDir = values.isDirectory
        else { return nil }
        var entry = FileEntry(
            url: url,
            isDirectory: isDir,
            children: isDir ? [] : nil,
            modifiedDate: values.contentModificationDate,
            creationDate: values.creationDate,
            fileSize: isDir ? nil : values.fileSize.map(Int64.init),
            labelNumber: values.labelNumber
        )
        entry.isCloudOnly = CloudFileStatus.isCloudOnly(path: url.path, isDirectory: isDir)
        return entry
    }
}

/// Metadata for a single file.
struct FileMetadata {
    let fileName: String
    let fileType: String
    let width: Int?
    let height: Int?
    let duration: TimeInterval?
    let modifiedDate: Date?
    let fileSize: Int64?
}
