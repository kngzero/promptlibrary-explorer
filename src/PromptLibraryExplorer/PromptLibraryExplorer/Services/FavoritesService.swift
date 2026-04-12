import Foundation

/// Manages a set of favorited/pinned file paths.
final class FavoritesService {
    static let shared = FavoritesService()

    private static let storageKey = "promptlibrary.favoritePaths"

    private init() {}

    func loadFavorites() -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode(Set<String>.self, from: data)
        else { return [] }
        return decoded
    }

    func saveFavorites(_ favorites: Set<String>) {
        if let data = try? JSONEncoder().encode(favorites) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    func toggleFavorite(path: String) -> Bool {
        var favorites = loadFavorites()
        if favorites.contains(path) {
            favorites.remove(path)
        } else {
            favorites.insert(path)
        }
        saveFavorites(favorites)
        return favorites.contains(path)
    }

    func isFavorite(path: String) -> Bool {
        loadFavorites().contains(path)
    }
}
