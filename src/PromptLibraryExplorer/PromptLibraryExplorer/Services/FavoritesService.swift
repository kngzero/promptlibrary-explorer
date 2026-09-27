import Foundation

/// Manages a set of favorited/pinned file paths.
///
/// The set is decoded from UserDefaults once and then served from memory;
/// every save writes through to UserDefaults.
final class FavoritesService {
    static let shared = FavoritesService()

    private static let storageKey = "promptlibrary.favoritePaths"

    private let lock = NSLock()
    private var cache: Set<String>?

    private init() {}

    func loadFavorites() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return cachedFavorites()
    }

    func saveFavorites(_ favorites: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        store(favorites)
    }

    func toggleFavorite(path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var favorites = cachedFavorites()
        if favorites.contains(path) {
            favorites.remove(path)
        } else {
            favorites.insert(path)
        }
        store(favorites)
        return favorites.contains(path)
    }

    func isFavorite(path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cachedFavorites().contains(path)
    }

    // MARK: - Private (call with the lock held)

    private func cachedFavorites() -> Set<String> {
        if let cache { return cache }
        let decoded: Set<String>
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let value = try? JSONDecoder().decode(Set<String>.self, from: data)
        {
            decoded = value
        } else {
            decoded = []
        }
        cache = decoded
        return decoded
    }

    private func store(_ favorites: Set<String>) {
        cache = favorites
        if let data = try? JSONEncoder().encode(favorites) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
