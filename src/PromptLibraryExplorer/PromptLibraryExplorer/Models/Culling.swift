import AppKit
import Foundation

// MARK: - Flags

/// Pick / reject flag per file (Lightroom convention). Stored path-keyed like
/// ratings (see `FlagBook` / `FlagStore`), so it follows renames and moves.
enum FileFlag: Int, Codable, CaseIterable, Identifiable {
    case reject = -1
    case unflagged = 0
    case pick = 1

    var id: Int { rawValue }

    /// State name ("Pick", "Unflagged", "Reject").
    var title: String {
        switch self {
        case .pick: return "Pick"
        case .unflagged: return "Unflagged"
        case .reject: return "Reject"
        }
    }

    /// Verb for menus and buttons ("Pick", "Unflag", "Reject").
    var actionTitle: String {
        switch self {
        case .pick: return "Pick"
        case .unflagged: return "Unflag"
        case .reject: return "Reject"
        }
    }

    /// Plural group title ("Picks", "Unflagged", "Rejects").
    var groupTitle: String {
        switch self {
        case .pick: return "Picks"
        case .unflagged: return "Unflagged"
        case .reject: return "Rejects"
        }
    }

    /// The bare key that sets this flag (owned by the key monitors, not menus).
    var keyHint: String {
        switch self {
        case .pick: return "P"
        case .unflagged: return "U"
        case .reject: return "X"
        }
    }

    var systemImage: String {
        switch self {
        case .pick: return "flag.fill"
        case .unflagged: return "flag"
        case .reject: return "xmark.circle.fill"
        }
    }
}

/// Listing / smart folder filter on flags.
enum FlagFilter: String, Codable, CaseIterable, Identifiable {
    case all
    case picks
    /// Unflagged + picks.
    case hideRejects
    case rejects

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All Flags"
        case .picks: return "Picks Only"
        case .hideRejects: return "Hide Rejects"
        case .rejects: return "Rejects Only"
        }
    }

    func includes(_ flag: FileFlag) -> Bool {
        switch self {
        case .all: return true
        case .picks: return flag == .pick
        case .hideRejects: return flag != .reject
        case .rejects: return flag == .reject
        }
    }
}

/// Path-keyed flags. A value type so the rename / trash / undo bookkeeping is
/// testable without the view model or real UserDefaults. Unflagged files have
/// no entry.
struct FlagBook: Equatable {
    private(set) var flags: [String: FileFlag] = [:]

    init(flags: [String: FileFlag] = [:]) {
        self.flags = flags.filter { $0.value != .unflagged }
    }

    func flag(for path: String) -> FileFlag {
        flags[path] ?? .unflagged
    }

    mutating func set(_ flag: FileFlag, for path: String) {
        if flag == .unflagged {
            flags.removeValue(forKey: path)
        } else {
            flags[path] = flag
        }
    }

    /// Moves every flag at or under `oldPath` to `newPath`. Returns false when
    /// nothing matched.
    @discardableResult
    mutating func migrate(from oldPath: String, to newPath: String) -> Bool {
        guard oldPath != newPath,
              let migrated = MetadataPathKeys.migratingKeys(of: flags, from: oldPath, to: newPath)
        else { return false }
        flags = migrated
        return true
    }

    /// Removes and returns every flag at or under `path`.
    mutating func removeAll(under path: String) -> [String: FileFlag] {
        var removed: [String: FileFlag] = [:]
        for key in flags.keys where MetadataPathKeys.isSameOrDescendant(key, of: path) {
            removed[key] = flags.removeValue(forKey: key)
        }
        return removed
    }

    /// Puts a snapshot taken at `oldPath` back, rewritten to `newPath`.
    mutating func restore(_ snapshot: [String: FileFlag], from oldPath: String, to newPath: String) {
        for (key, value) in snapshot {
            set(value, for: MetadataPathKeys.rewrite(key, from: oldPath, to: newPath) ?? key)
        }
    }
}

/// Persists flags as `[path: rawValue]` JSON. `defaults` is injectable for tests.
struct FlagStore {
    static let storageKey = "promptlibrary.flags"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> FlagBook {
        guard let data = defaults.data(forKey: Self.storageKey),
              let raw = try? JSONDecoder().decode([String: Int].self, from: data)
        else { return FlagBook() }
        return FlagBook(flags: raw.compactMapValues(FileFlag.init(rawValue:)))
    }

    func save(_ book: FlagBook) {
        if let data = try? JSONEncoder().encode(book.flags.mapValues(\.rawValue)) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}

// MARK: - Finder labels

/// A Finder colour label: the file's `URLResourceKey.labelNumberKey`. The raw
/// values are Finder's own numbering (verified against
/// `NSWorkspace.shared.fileLabels`, which lists
/// None, Gray, Green, Purple, Blue, Yellow, Red, Orange at indices 0…7, and by
/// round-tripping `labelNumber` → `tagNames`).
enum FinderLabel: Int, CaseIterable, Identifiable {
    case none = 0
    case gray = 1
    case green = 2
    case purple = 3
    case blue = 4
    case yellow = 5
    case red = 6
    case orange = 7

    var id: Int { rawValue }

    /// Finder's menu order (Red … Gray), without None.
    static let menuOrder: [FinderLabel] = [.red, .orange, .yellow, .green, .blue, .purple, .gray]

    /// Unknown / out-of-range numbers read as `.none`.
    init(labelNumber: Int?) {
        self = labelNumber.flatMap(FinderLabel.init(rawValue:)) ?? .none
    }

    private static let fallbackTitles = ["None", "Gray", "Green", "Purple", "Blue", "Yellow", "Red", "Orange"]

    /// Finder's (possibly user-renamed, localized) label names, read once.
    private static let workspaceTitles: [String] = {
        let names = NSWorkspace.shared.fileLabels
        return names.count == fallbackTitles.count ? names : fallbackTitles
    }()

    var title: String {
        let name = Self.workspaceTitles[rawValue]
        return name.isEmpty ? Self.fallbackTitles[rawValue] : name
    }

    /// The digit key for the four labels with a bare-key shortcut
    /// (Lightroom: 6 red, 7 yellow, 8 green, 9 blue).
    var keyHint: String? {
        switch self {
        case .red: return "6"
        case .yellow: return "7"
        case .green: return "8"
        case .blue: return "9"
        default: return nil
        }
    }

    static func forDigitKey(_ digit: Int) -> FinderLabel? {
        switch digit {
        case 6: return .red
        case 7: return .yellow
        case 8: return .green
        case 9: return .blue
        default: return nil
        }
    }

    /// Position in `menuOrder`; nil for `.none` (sorts last).
    var sortRank: Int? {
        Self.menuOrder.firstIndex(of: self)
    }
}

// MARK: - Cull actions & keys

/// One culling action: set a flag, a rating (0 clears) or a Finder label.
enum CullAction: Equatable {
    case flag(FileFlag)
    case rating(Int)
    case label(FinderLabel)

    /// Maps a bare (unmodified) key's characters to an action:
    /// P pick, X reject, U unflag, 0–5 rating, 6 red, 7 yellow, 8 green, 9 blue.
    init?(keyCharacters: String) {
        switch keyCharacters.lowercased() {
        case "p": self = .flag(.pick)
        case "x": self = .flag(.reject)
        case "u": self = .flag(.unflagged)
        case let digit where digit.count == 1 && digit.first?.isASCII == true:
            guard let value = Int(digit) else { return nil }
            if value <= 5 {
                self = .rating(value)
            } else if let label = FinderLabel.forDigitKey(value) {
                self = .label(label)
            } else {
                return nil
            }
        default:
            return nil
        }
    }

    /// Parses a key-down event. Only bare keys count: any ⌘ ⌃ ⌥ or ⇧ modifier
    /// means it isn't a culling key (so menu shortcuts and ⇧-digits pass through).
    init?(event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard modifiers.isEmpty, let characters = event.charactersIgnoringModifiers else { return nil }
        self.init(keyCharacters: characters)
    }

    /// Short feedback text ("Pick", "Rejected", "3 Stars", "Red").
    var feedbackTitle: String {
        switch self {
        case let .flag(flag):
            switch flag {
            case .pick: return "Picked"
            case .reject: return "Rejected"
            case .unflagged: return "Unflagged"
            }
        case let .rating(stars):
            return stars == 0 ? "No Rating" : (stars == 1 ? "1 Star" : "\(stars) Stars")
        case let .label(label):
            return label == .none ? "No Label" : label.title
        }
    }

    /// Whether this action applies to folders (Finder labels do; flags and
    /// ratings are for files).
    var appliesToFolders: Bool {
        if case .label = self { return true }
        return false
    }
}

/// Transient "what just happened" for the culling HUD's flash.
struct CullFeedback: Equatable {
    let id: Int
    let action: CullAction
    let count: Int
}
