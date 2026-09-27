import Foundation

/// Why a curation backup was taken.
enum CurationBackupReason: String, Codable, CaseIterable, Sendable {
    case daily
    case manual
    case preImport
    case preRestore
    case preReset
    case migration

    var title: String {
        switch self {
        case .daily: return "Daily"
        case .manual: return "Manual"
        case .preImport: return "Before import"
        case .preRestore: return "Before restore"
        case .preReset: return "Before reset"
        case .migration: return "Before upgrade"
        }
    }
}

/// One backup file, as listed in Restore from Backup….
struct CurationBackupInfo: Identifiable, Hashable, Sendable {
    let url: URL
    let createdAt: Date
    let reason: CurationBackupReason
    let machineName: String
    let counts: CurationCounts
    /// Lives in the user's extra backup folder rather than Application Support.
    let isInExtraFolder: Bool

    var id: String { url.path }

    static func == (lhs: CurationBackupInfo, rhs: CurationBackupInfo) -> Bool { lhs.url == rhs.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

/// Writes, lists and prunes curation bundle backups. Rolling backups live in
/// `directory` (Application Support/PromptLibraryExplorer/Backups); every backup is
/// also copied to the optional `extraDirectory` (e.g. a Dropbox folder). Retention:
/// 14 daily + 8 weekly daily backups, and the newest 20 event backups (before import,
/// restore, reset or upgrade). Only files this service named are ever pruned.
struct CurationBackupService: Sendable {
    let directory: URL
    var extraDirectory: URL?
    /// Distinguishes Macs sharing an extra folder in Dropbox.
    let machineTag: String

    static let dailyKeepDays = 14
    static let weeklyKeepWeeks = 8
    static let eventKeepCount = 20
    static let filePrefix = "curation-backup-"

    static var defaultDirectory: URL {
        CollectionServiceStorage.directoryURL.appendingPathComponent("Backups", isDirectory: true)
    }

    init(directory: URL = CurationBackupService.defaultDirectory, extraDirectory: URL? = nil, machineName: String = CurationDevice.machineName) {
        self.directory = directory
        self.extraDirectory = extraDirectory
        self.machineTag = Self.sanitizedTag(machineName)
    }

    static func sanitizedTag(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let mapped = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(mapped).split(separator: "-").joined(separator: "-")
        return String(collapsed.prefix(32)).isEmpty ? "Mac" : String(collapsed.prefix(32))
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    func fileName(for date: Date, reason: CurationBackupReason) -> String {
        "\(Self.filePrefix)\(Self.stampFormatter.string(from: date))-\(reason.rawValue)-\(machineTag).json"
    }

    /// Parses our own file names: (date, reason, machine tag).
    static func parse(fileName: String) -> (date: Date, reason: CurationBackupReason, machine: String)? {
        guard fileName.hasPrefix(filePrefix), fileName.hasSuffix(".json") else { return nil }
        let body = fileName.dropFirst(filePrefix.count).dropLast(5)
        let parts = body.split(separator: "-", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4,
              let date = stampFormatter.date(from: "\(parts[0])-\(parts[1])"),
              let reason = CurationBackupReason(rawValue: String(parts[2]))
        else { return nil }
        return (date, reason, String(parts[3]))
    }

    // MARK: Write

    /// Writes `data` (an encoded bundle) as a backup, mirrors it to the extra folder and
    /// prunes both. Returns the primary file.
    @discardableResult
    func write(_ data: Data, date: Date, reason: CurationBackupReason) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = fileName(for: date, reason: reason)
        var url = directory.appendingPathComponent(name)
        var counter = 2
        while fm.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent(name.replacingOccurrences(of: ".json", with: "-\(counter).json"))
            counter += 1
        }
        try data.write(to: url, options: [.atomic])
        prune(in: directory, now: date)

        if let extraDirectory {
            do {
                try fm.createDirectory(at: extraDirectory, withIntermediateDirectories: true)
                try data.write(to: extraDirectory.appendingPathComponent(url.lastPathComponent), options: [.atomic])
                prune(in: extraDirectory, now: date)
            } catch {
                NSLog("PromptLibraryExplorer: couldn't copy the backup to %@: %@", extraDirectory.path, error.localizedDescription)
            }
        }
        return url
    }

    // MARK: List

    /// Every backup in both folders (newest first), with header counts.
    func list() -> [CurationBackupInfo] {
        var seen = Set<String>()
        var result: [CurationBackupInfo] = []
        for (folder, isExtra) in [(directory, false)] + (extraDirectory.map { [($0, true)] } ?? []) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names where seen.insert(name).inserted {
                guard let parsed = Self.parse(fileName: name) else { continue }
                let url = folder.appendingPathComponent(name)
                let header = Self.readHeader(at: url)
                result.append(CurationBackupInfo(
                    url: url,
                    createdAt: header?.createdAt ?? parsed.date,
                    reason: parsed.reason,
                    machineName: header?.machineName ?? parsed.machine,
                    counts: header?.counts ?? CurationCounts(),
                    isInExtraFolder: isExtra
                ))
            }
        }
        return result.sorted { $0.createdAt > $1.createdAt }
    }

    /// Newest backup date of `reason` (any reason when nil) in the primary folder.
    func latestDate(reason: CurationBackupReason? = nil) -> Date? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap(Self.parse(fileName:))
            .filter { reason == nil || $0.reason == reason }
            .map(\.date)
            .max()
    }

    private struct Header: Decodable {
        var createdAt: Date?
        var machineName: String?
        var counts: CurationCounts?
    }

    private static func readHeader(at url: URL) -> Header? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        return try? CurationBundle.decoder().decode(Header.self, from: data)
    }

    // MARK: Retention

    /// Which of `backups` to keep. Pure, for tests.
    static func retained(
        _ backups: [(name: String, date: Date, reason: CurationBackupReason)],
        now: Date,
        calendar: Calendar = Calendar(identifier: .iso8601)
    ) -> Set<String> {
        var keep = Set<String>()
        let sorted = backups.sorted { $0.date > $1.date }

        // Dailies: the newest backup of each of the 14 most recent days; then the newest
        // of each of the 8 next-older weeks that no kept daily already covers.
        var keptDays = Set<DateComponents>()
        var coveredWeeks = Set<DateComponents>()
        var weeklyCount = 0
        for backup in sorted where backup.reason == .daily {
            let day = calendar.dateComponents([.year, .month, .day], from: backup.date)
            let week = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: backup.date)
            if keptDays.count < dailyKeepDays || keptDays.contains(day) {
                if keptDays.insert(day).inserted {
                    keep.insert(backup.name)
                    coveredWeeks.insert(week)
                }
                continue
            }
            if weeklyCount < weeklyKeepWeeks, coveredWeeks.insert(week).inserted {
                weeklyCount += 1
                keep.insert(backup.name)
            }
        }

        let events = sorted.filter { $0.reason != .daily }
        for backup in events.prefix(eventKeepCount) { keep.insert(backup.name) }
        return keep
    }

    /// Deletes our own backups that fall outside the retention policy (only this Mac's
    /// files in a shared extra folder).
    func prune(in folder: URL, now: Date) {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        let ours = names.compactMap { name -> (name: String, date: Date, reason: CurationBackupReason)? in
            guard let parsed = Self.parse(fileName: name), parsed.machine == machineTag else { return nil }
            return (name, parsed.date, parsed.reason)
        }
        let keep = Self.retained(ours, now: now)
        for backup in ours where !keep.contains(backup.name) {
            try? fm.removeItem(at: folder.appendingPathComponent(backup.name))
        }
    }
}
