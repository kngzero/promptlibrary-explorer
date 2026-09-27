import Foundation

/// Errors thrown by the readers/writers. Element-level problems never throw —
/// a bad element is skipped instead.
public enum ArtOfficialFormatError: Error, Sendable, Equatable, CustomStringConvertible {
    case unreadable(String)
    case notJSON
    case unsupportedFormat(String)
    case archive(String)
    case writeFailed(String)

    public var description: String {
        switch self {
        case .unreadable(let m): return "Unreadable file: \(m)"
        case .notJSON: return "The file is not JSON or a supported archive."
        case .unsupportedFormat(let m): return "Unsupported format: \(m)"
        case .archive(let m): return "Archive error: \(m)"
        case .writeFailed(let m): return "Write failed: \(m)"
        }
    }
}

extension ArtOfficialFormatError: LocalizedError {
    public var errorDescription: String? { description }
}

enum FileLoader {
    /// Memory-maps when possible so large base64 documents are not copied.
    static func load(_ url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw ArtOfficialFormatError.unreadable(error.localizedDescription)
        }
    }

    static func write(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw ArtOfficialFormatError.writeFailed(error.localizedDescription)
        }
    }
}
