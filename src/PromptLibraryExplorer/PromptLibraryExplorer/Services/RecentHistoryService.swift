import Foundation

struct RecentItem: Codable, Identifiable, Hashable {
    let path: String
    let name: String
    let timestamp: Date

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
}

final class RecentHistoryService {
    static let shared = RecentHistoryService()

    static let foldersKey = "promptlibrary.recentFolders"
    private static let maxItems = 10

    private let defaults: UserDefaults

    /// `defaults` is injectable for tests; the app uses `shared`.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadRecentFolders() -> [RecentItem] {
        loadAllRecentFolders().filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Every stored item, including folders that are currently missing
    /// (backups keep them; an unmounted drive may come back).
    func loadAllRecentFolders() -> [RecentItem] {
        guard let data = defaults.data(forKey: Self.foldersKey),
              let items = try? JSONDecoder().decode([RecentItem].self, from: data)
        else { return [] }
        return items
    }

    /// Replaces the whole list (curation import / restore).
    func replaceRecentFolders(_ items: [RecentItem]) {
        save(Array(items.prefix(Self.maxItems)))
    }

    func addRecentFolder(_ url: URL) {
        let name = url.lastPathComponent
        let item = RecentItem(path: url.path, name: name, timestamp: Date())
        var items = loadRecentFolders().filter { $0.path != item.path }
        items.insert(item, at: 0)
        if items.count > Self.maxItems { items = Array(items.prefix(Self.maxItems)) }
        save(items)
    }

    func removeRecentFolder(path: String) {
        save(loadRecentFolders().filter { $0.path != path })
    }

    func clearRecentFolders() {
        save([])
    }

    private func save(_ items: [RecentItem]) {
        if let data = try? JSONEncoder().encode(items) {
            defaults.set(data, forKey: Self.foldersKey)
        }
    }
}
