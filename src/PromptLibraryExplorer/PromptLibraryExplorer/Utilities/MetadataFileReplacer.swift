import Foundation

/// Atomically replaces a file's contents with freshly built (and already verified) bytes.
///
/// The new bytes are written to a temporary file on the same volume, then swapped in with
/// `FileManager.replaceItemAt`, which keeps the original's attributes. No backup or temp
/// files are left in the user's folder whether the swap succeeds or fails.
enum MetadataFileReplacer {
    static func replaceContents(of url: URL, with data: Data) throws {
        let fileManager = FileManager.default
        let temporaryDirectory = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: url,
            create: true
        )
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let temporaryURL = temporaryDirectory.appendingPathComponent(url.lastPathComponent)
        try data.write(to: temporaryURL)
        _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL)
    }
}
