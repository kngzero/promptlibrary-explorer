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

    private static let foldersKey = "promptlibrary.recentFolders"
    private static let maxItems = 10

    private init() {}

    func loadRecentFolders() -> [RecentItem] {
        guard let data = UserDefaults.standard.data(forKey: Self.foldersKey),
              let items = try? JSONDecoder().decode([RecentItem].self, from: data)
        else { return [] }
        return items.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func addRecentFolder(_ url: URL) {
        let name = url.lastPathComponent
        let item = RecentItem(path: url.path, name: name, timestamp: Date())
        var items = loadRecentFolders().filter { $0.path != item.path }
        items.insert(item, at: 0)
        if items.count > Self.maxItems { items = Array(items.prefix(Self.maxItems)) }
        save(items)
    }

    func clearRecentFolders() {
        save([])
    }

    private func save(_ items: [RecentItem]) {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: Self.foldersKey)
        }
    }
}
