import Foundation

/// Every file's edit recipe, keyed by absolute path. Identity recipes are never stored.
struct EditBook: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int = EditBook.currentVersion
    var recipes: [String: EditRecipe] = [:]

    init(recipes: [String: EditRecipe] = [:]) {
        self.recipes = recipes
        normalize()
    }

    enum CodingKeys: String, CodingKey { case version, recipes }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        // One bad entry mustn't lose the rest.
        let raw = (try? c.decodeIfPresent([String: LossyRecipe].self, forKey: .recipes)) ?? [:]
        recipes = raw.compactMapValues(\.recipe)
        normalize()
    }

    private struct LossyRecipe: Decodable {
        let recipe: EditRecipe?
        init(from decoder: Decoder) throws {
            recipe = try? EditRecipe(from: decoder)
        }
    }

    mutating func normalize() {
        recipes = recipes.compactMapValues { recipe in
            let normalized = recipe.normalized()
            return normalized.isIdentity ? nil : normalized
        }
    }

    /// Sets (or with nil / an identity recipe, removes) `path`'s recipe; returns the old one.
    @discardableResult
    mutating func set(_ recipe: EditRecipe?, for path: String) -> EditRecipe? {
        let previous = recipes[path]
        if let recipe, !recipe.normalized().isIdentity {
            recipes[path] = recipe.normalized()
        } else {
            recipes.removeValue(forKey: path)
        }
        return previous
    }

    /// Rename / move: every recipe at or under `oldPath` follows. False when nothing matched.
    @discardableResult
    mutating func migrate(from oldPath: String, to newPath: String) -> Bool {
        guard oldPath != newPath, let migrated = MetadataPathKeys.migratingKeys(of: recipes, from: oldPath, to: newPath) else { return false }
        recipes = migrated
        return true
    }

    /// Removes and returns every recipe at or under `path` (trash, replace).
    mutating func removeAll(under path: String) -> [String: EditRecipe] {
        let keys = recipes.keys.filter { MetadataPathKeys.isSameOrDescendant($0, of: path) }
        var removed: [String: EditRecipe] = [:]
        for key in keys { removed[key] = recipes.removeValue(forKey: key) }
        return removed
    }

    /// Puts a snapshot taken at `oldPath` back under `newPath` (undo of a trash).
    mutating func restore(_ snapshot: [String: EditRecipe], from oldPath: String, to newPath: String) {
        for (key, recipe) in snapshot {
            recipes[MetadataPathKeys.rewrite(key, from: oldPath, to: newPath) ?? key] = recipe
        }
        normalize()
    }
}

/// Persists the edit book as JSON in `defaults` (injectable for tests) and posts
/// `CurationStoreEvents` so backups, the library data file and sync pick it up.
struct EditStore {
    static let storageKey = "promptlibrary.edits"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> EditBook {
        guard let data = defaults.data(forKey: Self.storageKey),
              let book = try? JSONDecoder().decode(EditBook.self, from: data)
        else { return EditBook() }
        return book
    }

    func save(_ book: EditBook) {
        var normalized = book
        normalized.normalize()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(normalized) {
            defaults.set(data, forKey: Self.storageKey)
            CurationStoreEvents.post(.edits)
        }
    }
}
