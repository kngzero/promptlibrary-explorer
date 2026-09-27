import Compression
import Foundation

/// Minimal, defensive, read-only ZIP reader (stored + deflate). Used for the legacy
/// `.mlmboard` archive format. Entries are listed from the central directory (so
/// data descriptors are handled) and inflated lazily, one at a time.
public struct ZipArchive: Sendable {
    public struct Limits: Sendable, Hashable {
        public var maxEntries: Int
        public var maxTotalUncompressed: Int
        public var maxEntryUncompressed: Int

        public static let `default` = Limits(
            maxEntries: 2_000,
            maxTotalUncompressed: 512 * 1024 * 1024,
            maxEntryUncompressed: 64 * 1024 * 1024
        )

        public init(maxEntries: Int, maxTotalUncompressed: Int, maxEntryUncompressed: Int) {
            self.maxEntries = maxEntries
            self.maxTotalUncompressed = maxTotalUncompressed
            self.maxEntryUncompressed = maxEntryUncompressed
        }
    }

    public struct Entry: Sendable, Hashable {
        public let name: String
        public let method: UInt16          // 0 = stored, 8 = deflate
        public let compressedSize: Int
        public let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    /// Entries that passed validation (safe path, supported method, within limits).
    public let entries: [Entry]
    /// Names of entries that were present but ignored (unsafe path, encrypted, over limits…).
    public let rejectedEntryNames: [String]
    private let data: Data
    private let limits: Limits

    public static func isZip(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let s = data.startIndex
        return data[s] == 0x50 && data[s + 1] == 0x4B && data[s + 2] == 0x03 && data[s + 3] == 0x04
    }

    public init(data: Data, limits: Limits = .default) throws {
        // Re-base so offsets are 0-based regardless of slice origin.
        let data = data.startIndex == 0 ? data : Data(data)
        self.data = data
        self.limits = limits

        guard let eocd = Self.findEndOfCentralDirectory(data) else {
            throw ArtOfficialFormatError.archive("End of central directory not found")
        }
        let totalEntries = Int(Self.u16(data, eocd + 10) ?? 0)
        let cdSize = Int(Self.u32(data, eocd + 12) ?? 0)
        let cdOffset = Int(Self.u32(data, eocd + 16) ?? 0)
        if totalEntries == 0xFFFF || cdOffset == 0xFFFF_FFFF {
            throw ArtOfficialFormatError.archive("ZIP64 archives are not supported")
        }
        guard totalEntries <= limits.maxEntries else {
            throw ArtOfficialFormatError.archive("Too many entries (\(totalEntries))")
        }
        guard cdOffset >= 0, cdOffset <= data.count, cdSize >= 0, cdOffset + cdSize <= data.count else {
            throw ArtOfficialFormatError.archive("Central directory out of bounds")
        }

        var accepted: [Entry] = []
        var rejected: [String] = []
        var total = 0
        var p = cdOffset
        let cdEnd = cdOffset + cdSize
        var seen = 0
        while p + 46 <= cdEnd, seen < totalEntries {
            guard Self.u32(data, p) == 0x0201_4B50 else { break }
            seen += 1
            let flags = Self.u16(data, p + 8) ?? 0
            let method = Self.u16(data, p + 10) ?? 0
            let csize = Int(Self.u32(data, p + 20) ?? 0)
            let usize = Int(Self.u32(data, p + 24) ?? 0)
            let nameLen = Int(Self.u16(data, p + 28) ?? 0)
            let extraLen = Int(Self.u16(data, p + 30) ?? 0)
            let commentLen = Int(Self.u16(data, p + 32) ?? 0)
            let localOffset = Int(Self.u32(data, p + 42) ?? 0)
            let nameStart = p + 46
            guard nameStart + nameLen <= data.count else { break }
            let nameBytes = data.subdata(in: nameStart..<(nameStart + nameLen))
            let name = String(data: nameBytes, encoding: .utf8)
                ?? String(data: nameBytes, encoding: .isoLatin1) ?? ""
            p = nameStart + nameLen + extraLen + commentLen

            if name.hasSuffix("/") { continue }                    // directory
            guard let safe = Self.sanitizedPath(name) else { rejected.append(name); continue }
            if flags & 0x1 != 0 { rejected.append(name); continue } // encrypted
            guard method == 0 || method == 8 else { rejected.append(name); continue }
            if csize == 0xFFFF_FFFF || usize == 0xFFFF_FFFF { rejected.append(name); continue }
            guard usize <= limits.maxEntryUncompressed else { rejected.append(name); continue }
            guard total + usize <= limits.maxTotalUncompressed else { rejected.append(name); continue }
            guard localOffset + 30 <= data.count, csize <= data.count else { rejected.append(name); continue }
            if method == 0 && csize != usize { rejected.append(name); continue }
            total += usize
            accepted.append(Entry(name: safe, method: method, compressedSize: csize,
                                  uncompressedSize: usize, localHeaderOffset: localOffset))
        }
        self.entries = accepted
        self.rejectedEntryNames = rejected
    }

    public func entry(named name: String) -> Entry? {
        entries.first { $0.name == name }
    }

    /// Case-insensitive lookup by last path component.
    public func entry(lastPathComponent: String) -> Entry? {
        let target = lastPathComponent.lowercased()
        return entries.first { ($0.name.split(separator: "/").last.map(String.init) ?? $0.name).lowercased() == target }
    }

    /// Returns the uncompressed bytes of an entry, or nil when it is damaged or
    /// would inflate beyond its declared size.
    public func extract(_ entry: Entry) -> Data? {
        let lh = entry.localHeaderOffset
        guard Self.u32(data, lh) == 0x0403_4B50,
              let nameLen = Self.u16(data, lh + 26),
              let extraLen = Self.u16(data, lh + 28) else { return nil }
        let start = lh + 30 + Int(nameLen) + Int(extraLen)
        let end = start + entry.compressedSize
        guard start >= 0, end <= data.count, start <= end else { return nil }

        if entry.method == 0 {
            return data.subdata(in: start..<end)
        }
        if entry.uncompressedSize == 0 { return Data() }
        // One extra byte of headroom detects streams that inflate past their declared size.
        let capacity = entry.uncompressedSize + 1
        var output = Data(count: capacity)
        let written: Int = output.withUnsafeMutableBytes { outRaw -> Int in
            data.withUnsafeBytes { inRaw -> Int in
                guard let outBase = outRaw.bindMemory(to: UInt8.self).baseAddress,
                      let inBase = inRaw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    outBase, capacity,
                    inBase + start, entry.compressedSize,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == entry.uncompressedSize else { return nil }
        output.removeLast(capacity - written)
        return output
    }

    // MARK: - Helpers

    /// nil for absolute paths, drive letters, backslashes or any `..` component.
    static func sanitizedPath(_ name: String) -> String? {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0") else { return nil }
        if name.count >= 2, name[name.index(after: name.startIndex)] == ":" { return nil }
        let parts = name.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty else { return nil }
        for part in parts where part == ".." { return nil }
        return parts.filter { $0 != "." }.joined(separator: "/")
    }

    private static func findEndOfCentralDirectory(_ data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let lowest = max(0, data.count - 22 - 0xFFFF)
        var i = data.count - 22
        while i >= lowest {
            if u32(data, i) == 0x0605_4B50 { return i }
            i -= 1
        }
        return nil
    }

    static func u16(_ data: Data, _ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    static func u32(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }
}
