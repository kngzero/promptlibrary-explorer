import Foundation

/// Converts between the app's absolute-path stores and the root-relative
/// `CurationPortableState` the library data file syncs.
@MainActor
enum CurationLibraryAdapter {
    // MARK: Stores → portable

    /// What the stores hold now for files under `root`, plus the global objects
    /// (tag definitions, sets, smart folders, and collections that touch this root).
    static func snapshot(root rawRoot: String, stores: CurationStores) -> CurationPortableState {
        let root = CurationPaths.trimmedRoot(rawRoot)
        var state = CurationPortableState()

        let tags = stores.tags.loadTags()
        let tagsByID = Dictionary(tags.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for tag in tags {
            let key = tag.name.lowercased()
            if state.tags[key] == nil {
                state.tags[key] = LibraryTagDefinition(name: tag.name, colorHex: tag.colorHex)
            }
        }

        func update(_ path: String, _ body: (inout PortableFileValues) -> Void) {
            guard let relative = CurationPaths.relative(path, to: root), !relative.isEmpty else { return }
            var values = state.files[relative] ?? PortableFileValues()
            body(&values)
            state.files[relative] = values.isEmpty ? nil : values
        }

        for (path, rating) in stores.settings.loadRatings() where rating > 0 {
            update(path) { $0.rating = min(5, rating) }
        }
        for (path, flag) in stores.flags.load().flags where flag != .unflagged {
            update(path) { $0.flag = flag.rawValue }
        }
        for (path, ids) in stores.tags.loadAssignments() {
            let names = tagKeys(for: ids, tagsByID: tagsByID)
            guard !names.isEmpty else { continue }
            update(path) { $0.tags = names }
        }
        for path in stores.favorites.loadFavorites() {
            update(path) { $0.favorite = true }
        }

        for (folder, items) in stores.settings.loadCustomOrders() {
            guard let relativeFolder = CurationPaths.relative(folder, to: root) else { continue }
            state.customOrders[relativeFolder] = items.compactMap { CurationPaths.relative($0, to: root) }
        }

        for collection in stores.collections.all() {
            let inside = collection.paths.compactMap { CurationPaths.relative($0, to: root) }
            // Collections made entirely of files in other libraries stay out of this file.
            guard !inside.isEmpty || collection.paths.isEmpty else { continue }
            state.collections[collection.id.uuidString] = LibraryCollectionValue(
                name: collection.name,
                createdAt: CurationDateFormat.wholeSecondString(from: collection.createdAt),
                parentID: collection.parentID,
                items: inside
            )
        }
        for set in stores.collections.allSets() {
            state.collectionSets[set.id.uuidString] = LibrarySetValue(
                name: set.name,
                createdAt: CurationDateFormat.wholeSecondString(from: set.createdAt),
                parentID: set.parentID
            )
        }
        for folder in stores.smartFolders.loadSmartFolders() {
            var criteria = folder.criteria
            let names = tagKeys(for: Array(criteria.tagIDs), tagsByID: tagsByID)
            criteria.tagIDs = []
            state.smartFolders[folder.id.uuidString] = LibrarySmartFolderValue(
                name: folder.name,
                createdAt: CurationDateFormat.wholeSecondString(from: folder.createdAt),
                criteria: criteria,
                tagNames: names
            )
        }
        let stackBook = stores.stacks.load()
        for stack in stackBook.stacks {
            let inside = stack.paths.compactMap { CurationPaths.relative($0, to: root) }.filter { !$0.isEmpty }
            // Stacks of files in other libraries stay out of this file.
            guard inside.count >= 2 else { continue }
            state.stacks[stack.id.uuidString] = LibraryStackValue(
                createdAt: CurationDateFormat.wholeSecondString(from: stack.createdAt),
                items: inside,
                cover: stack.coverPath.flatMap { CurationPaths.relative($0, to: root) }
            )
        }
        for path in stackBook.excludedPaths {
            guard let relative = CurationPaths.relative(path, to: root), !relative.isEmpty else { continue }
            state.stackExclusions[relative] = true
        }
        return state
    }

    /// Sorted, case-insensitively unique names of `ids` (unknown ids are skipped).
    static func tagNames(for ids: [UUID], tagsByID: [UUID: FileTag]) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for id in ids {
            guard let tag = tagsByID[id], seen.insert(tag.name.lowercased()).inserted else { continue }
            names.append(tag.name)
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Sorted lowercased names: how per-file tags are keyed in the library file, so two
    /// Macs spelling a tag differently ("Hero" / "hero") agree.
    static func tagKeys(for ids: [UUID], tagsByID: [UUID: FileTag]) -> [String] {
        Array(Set(ids.compactMap { tagsByID[$0]?.name.lowercased() })).sorted()
    }

    // MARK: Portable → stores

    /// Writes every value where `target` differs from `base` (the snapshot the merge was
    /// computed from). A value the user changed since `base` was taken is left alone; the
    /// next sync stamps it as a local change. Returns how many values were written.
    @discardableResult
    static func apply(
        target: CurationPortableState,
        base: CurationPortableState,
        root rawRoot: String,
        stores: CurationStores
    ) -> Int {
        let root = CurationPaths.trimmedRoot(rawRoot)
        let fresh = snapshot(root: root, stores: stores)
        var applied = 0

        var ratings = stores.settings.loadRatings()
        var flags = stores.flags.load()
        var assignments = stores.tags.loadAssignments()
        var favorites = stores.favorites.loadFavorites()
        var tags = stores.tags.loadTags()
        var ratingsChanged = false, flagsChanged = false, assignmentsChanged = false
        var favoritesChanged = false, tagsChanged = false

        var tagIDByName: [String: UUID] = [:]
        for tag in tags where tagIDByName[tag.name.lowercased()] == nil {
            tagIDByName[tag.name.lowercased()] = tag.id
        }
        func tagID(named name: String) -> UUID {
            let key = name.lowercased()
            if let id = tagIDByName[key] { return id }
            let colour = target.tags[key]?.colorHex ?? FinderTagMerge.defaultColour(for: name)
            let tag = FileTag(name: target.tags[key]?.name ?? name, colorHex: colour)
            tags.append(tag)
            tagsChanged = true
            tagIDByName[key] = tag.id
            return tag.id
        }

        // Tag definitions first (names/colours), so new assignments find them.
        for key in Set(target.tags.keys).union(base.tags.keys) {
            let wanted = target.tags[key], was = base.tags[key]
            guard wanted != was, fresh.tags[key] == was, let wanted else { continue }
            if let index = tags.firstIndex(where: { $0.name.lowercased() == key }) {
                if tags[index].name != wanted.name || tags[index].colorHex != wanted.colorHex {
                    tags[index].name = wanted.name
                    tags[index].colorHex = wanted.colorHex
                    tagsChanged = true
                    applied += 1
                }
            } else {
                _ = tagID(named: wanted.name)
                applied += 1
            }
        }

        for key in Set(target.files.keys).union(base.files.keys) {
            let wanted = target.files[key] ?? PortableFileValues()
            let was = base.files[key] ?? PortableFileValues()
            guard wanted != was else { continue }
            let now = fresh.files[key] ?? PortableFileValues()
            let path = CurationPaths.absolute(key, in: root)

            if wanted.rating != was.rating, now.rating == was.rating {
                if let rating = wanted.rating { ratings[path] = rating } else { ratings.removeValue(forKey: path) }
                ratingsChanged = true
                applied += 1
            }
            if wanted.flag != was.flag, now.flag == was.flag {
                flags.set(wanted.flag.flatMap(FileFlag.init(rawValue:)) ?? .unflagged, for: path)
                flagsChanged = true
                applied += 1
            }
            if wanted.tags != was.tags, now.tags == was.tags {
                let ids = (wanted.tags ?? []).map(tagID(named:))
                if ids.isEmpty { assignments.removeValue(forKey: path) } else { assignments[path] = ids }
                assignmentsChanged = true
                applied += 1
            }
            if wanted.favorite != was.favorite, now.favorite == was.favorite {
                if wanted.favorite == true { favorites.insert(path) } else { favorites.remove(path) }
                favoritesChanged = true
                applied += 1
            }
        }

        // A tag deleted elsewhere is removed here only once nothing uses it any more.
        for key in Set(base.tags.keys).subtracting(target.tags.keys) where fresh.tags[key] == base.tags[key] {
            guard let index = tags.firstIndex(where: { $0.name.lowercased() == key }) else { continue }
            let id = tags[index].id
            let inUse = assignments.values.contains { $0.contains(id) }
                || stores.smartFolders.loadSmartFolders().contains { $0.criteria.tagIDs.contains(id) }
            guard !inUse else { continue }
            tags.remove(at: index)
            tagsChanged = true
            applied += 1
        }

        if tagsChanged { stores.tags.saveTags(tags) }
        if ratingsChanged { stores.settings.saveRatings(ratings) }
        if flagsChanged { stores.flags.save(flags) }
        if assignmentsChanged { stores.tags.saveAssignments(assignments) }
        if favoritesChanged { stores.favorites.saveFavorites(favorites) }

        // Custom orders
        var orders = stores.settings.loadCustomOrders()
        var ordersChanged = false
        for key in Set(target.customOrders.keys).union(base.customOrders.keys) {
            let wanted = target.customOrders[key], was = base.customOrders[key]
            guard wanted != was, fresh.customOrders[key] == was else { continue }
            let folder = CurationPaths.absolute(key, in: root)
            if let wanted {
                orders[folder] = wanted.map { CurationPaths.absolute($0, in: root) }
            } else {
                orders.removeValue(forKey: folder)
            }
            ordersChanged = true
            applied += 1
        }
        if ordersChanged { stores.settings.saveCustomOrders(orders) }

        applied += applyCollections(target: target, base: base, fresh: fresh, root: root, stores: stores)
        applied += applyStacks(target: target, base: base, fresh: fresh, root: root, stores: stores)
        applied += applySmartFolders(target: target, base: base, fresh: fresh, stores: stores, tagID: { name in
            // Smart folders can name tags nobody has yet.
            let key = name.lowercased()
            if let existing = stores.tags.loadTags().first(where: { $0.name.lowercased() == key }) { return existing.id }
            let tag = FileTag(name: target.tags[key]?.name ?? name, colorHex: target.tags[key]?.colorHex ?? FinderTagMerge.defaultColour(for: name))
            stores.tags.addTag(tag)
            return tag.id
        })
        return applied
    }

    private static func applyCollections(
        target: CurationPortableState,
        base: CurationPortableState,
        fresh: CurationPortableState,
        root: String,
        stores: CurationStores
    ) -> Int {
        var collections = stores.collections.all()
        var sets = stores.collections.allSets()
        var applied = 0

        for key in Set(target.collectionSets.keys).union(base.collectionSets.keys) {
            let wanted = target.collectionSets[key], was = base.collectionSets[key]
            guard wanted != was, fresh.collectionSets[key] == was, let id = UUID(uuidString: key) else { continue }
            if let wanted {
                let created = CurationDateFormat.date(from: wanted.createdAt) ?? Date()
                if let index = sets.firstIndex(where: { $0.id == id }) {
                    sets[index].name = wanted.name
                    sets[index].parentID = wanted.parentID
                } else {
                    sets.append(CollectionSet(id: id, name: wanted.name, createdAt: created, parentID: wanted.parentID))
                }
            } else if let index = sets.firstIndex(where: { $0.id == id }) {
                // Children move up to the removed set's parent, as a local delete does.
                let parent = sets[index].parentID
                sets.remove(at: index)
                for i in sets.indices where sets[i].parentID == id { sets[i].parentID = parent }
                for i in collections.indices where collections[i].parentID == id { collections[i].parentID = parent }
            }
            applied += 1
        }

        for key in Set(target.collections.keys).union(base.collections.keys) {
            let wanted = target.collections[key], was = base.collections[key]
            guard wanted != was, fresh.collections[key] == was, let id = UUID(uuidString: key) else { continue }
            let index = collections.firstIndex(where: { $0.id == id })
            // Members in other libraries are this Mac's business; keep them.
            let outside = index.map { collections[$0].paths.filter { CurationPaths.relative($0, to: root) == nil } } ?? []
            if let wanted {
                let paths = wanted.items.map { CurationPaths.absolute($0, in: root) } + outside
                if let index {
                    collections[index].name = wanted.name
                    collections[index].parentID = wanted.parentID
                    collections[index].paths = paths
                } else {
                    let created = CurationDateFormat.date(from: wanted.createdAt) ?? Date()
                    collections.append(FileCollection(id: id, name: wanted.name, paths: paths, createdAt: created, parentID: wanted.parentID))
                }
            } else if let index {
                if outside.isEmpty {
                    collections.remove(at: index)
                } else {
                    collections[index].paths = outside
                }
            }
            applied += 1
        }

        if applied > 0 {
            stores.collections.replaceAll(collections: collections, sets: sets)
        }
        return applied
    }

    private static func applyStacks(
        target: CurationPortableState,
        base: CurationPortableState,
        fresh: CurationPortableState,
        root: String,
        stores: CurationStores
    ) -> Int {
        var book = stores.stacks.load()
        var applied = 0
        for key in Set(target.stacks.keys).union(base.stacks.keys) {
            let wanted = target.stacks[key], was = base.stacks[key]
            guard wanted != was, fresh.stacks[key] == was, let id = UUID(uuidString: key) else { continue }
            let index = book.stacks.firstIndex(where: { $0.id == id })
            // Members in other libraries are this Mac's business; keep them.
            let outside = index.map { book.stacks[$0].paths.filter { CurationPaths.relative($0, to: root) == nil } } ?? []
            if let wanted {
                let paths = wanted.items.map { CurationPaths.absolute($0, in: root) } + outside
                let cover = wanted.cover.map { CurationPaths.absolute($0, in: root) }
                if let index {
                    book.stacks[index].paths = paths
                    book.stacks[index].coverPath = cover
                } else {
                    let created = CurationDateFormat.date(from: wanted.createdAt) ?? Date()
                    book.stacks.append(ManualStack(id: id, paths: paths, coverPath: cover, createdAt: created))
                }
            } else if let index {
                if outside.count >= 2 {
                    book.stacks[index].paths = outside
                } else {
                    book.stacks.remove(at: index)
                }
            }
            applied += 1
        }
        for key in Set(target.stackExclusions.keys).union(base.stackExclusions.keys) {
            let wanted = target.stackExclusions[key], was = base.stackExclusions[key]
            guard wanted != was, fresh.stackExclusions[key] == was else { continue }
            let path = CurationPaths.absolute(key, in: root)
            if wanted == true { book.excludedPaths.insert(path) } else { book.excludedPaths.remove(path) }
            applied += 1
        }
        if applied > 0 {
            book.normalize()
            stores.stacks.save(book)
        }
        return applied
    }

    private static func applySmartFolders(
        target: CurationPortableState,
        base: CurationPortableState,
        fresh: CurationPortableState,
        stores: CurationStores,
        tagID: (String) -> UUID
    ) -> Int {
        var folders = stores.smartFolders.loadSmartFolders()
        var applied = 0
        for key in Set(target.smartFolders.keys).union(base.smartFolders.keys) {
            let wanted = target.smartFolders[key], was = base.smartFolders[key]
            guard wanted != was, fresh.smartFolders[key] == was, let id = UUID(uuidString: key) else { continue }
            if let wanted {
                var criteria = wanted.criteria
                criteria.tagIDs = Set(wanted.tagNames.map(tagID))
                if let index = folders.firstIndex(where: { $0.id == id }) {
                    folders[index].name = wanted.name
                    folders[index].criteria = criteria
                } else {
                    var folder = SmartFolder(name: wanted.name, criteria: criteria)
                    folder.id = id
                    folder.createdAt = CurationDateFormat.date(from: wanted.createdAt) ?? Date()
                    folders.append(folder)
                }
            } else {
                folders.removeAll { $0.id == id }
            }
            applied += 1
        }
        if applied > 0 { stores.smartFolders.saveSmartFolders(folders) }
        return applied
    }
}
