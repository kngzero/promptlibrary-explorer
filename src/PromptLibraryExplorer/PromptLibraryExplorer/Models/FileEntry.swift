import Foundation

/// Represents a file or directory in the file system.
struct FileEntry: Identifiable, Hashable {
    let id: String // absolute path
    let url: URL
    let name: String
    let isDirectory: Bool
    var children: [FileEntry]?

    var path: String { url.path }

    init(url: URL, isDirectory: Bool, children: [FileEntry]? = nil) {
        self.id = url.path
        self.url = url
        self.name = url.lastPathComponent
        self.isDirectory = isDirectory
        self.children = children
    }
}

/// Metadata for a single file.
struct FileMetadata {
    let fileName: String
    let fileType: String
    let width: Int?
    let height: Int?
    let modifiedDate: Date?
    let fileSize: Int64?
}
