import Foundation

/// Reads `.stry` / `.mlseq` (web `AppState`, snake_case, plus Mac extension keys).
/// Mirrors Story for Mac's `ProjectIO.restore` defaults, but leniently: elements
/// without an `id` or with wrong types are skipped instead of failing the file.
///
/// Orphans: scenes whose `project_id` matches no project and shots whose `scene_id`
/// matches no scene are kept. With exactly one project they attach to it (orphan
/// shots in a trailing "Unassigned" scene); otherwise they go to a synthetic
/// "Unassigned" project (`isUnassigned == true`).
public enum StoryReader {
    public static let unassignedName = "Unassigned"

    public static func read(from url: URL) throws -> StoryDocument {
        try read(data: FileLoader.load(url))
    }

    public static func read(data: Data) throws -> StoryDocument {
        guard let root = JSON.parseObject(data) else { throw ArtOfficialFormatError.notJSON }
        guard root["projects"] is [Any] || root["scenes"] is [Any] || root["shots"] is [Any] else {
            throw ArtOfficialFormatError.unsupportedFormat("No projects/scenes/shots arrays")
        }
        var doc = parse(root)
        doc.sourceByteCount = data.count
        return doc
    }

    static func parse(_ root: JSONObject) -> StoryDocument {
        // Projects
        var projects: [StoryProject] = []
        var seenProjects = Set<String>()
        for (i, p) in JSON.objects(root, "projects").enumerated() {
            guard let id = JSON.nonEmptyString(p, "id"), seenProjects.insert(id).inserted else { continue }
            let dates = JSON.object(p, "dates")
            projects.append(StoryProject(
                id: id,
                index: JSON.int(p, "index") ?? i,
                title: JSON.nonEmptyString(p, "title") ?? "Untitled",
                code: JSON.string(p, "code") ?? "",
                status: JSON.nonEmptyString(p, "status") ?? "Planning",
                logline: JSON.nonEmptyString(p, "logline"),
                director: JSON.nonEmptyString(p, "director"),
                producer: JSON.nonEmptyString(p, "producer"),
                productionNotes: JSON.nonEmptyString(p, "production_notes", "productionNotes"),
                aspectRatio: JSON.nonEmptyString(p, "aspectRatio", "aspect_ratio") ?? "16:9",
                dateStart: JSON.nonEmptyString(dates, "start"),
                dateEnd: JSON.nonEmptyString(dates, "end"),
                coverImage: JSON.string(p, "cover_image", "coverImage").flatMap { EmbeddedImage.parse($0) }
            ))
        }

        // Scenes
        struct PendingScene { var scene: StoryScene; var projectId: String? }
        var scenes: [PendingScene] = []
        var sceneIndexByID: [String: Int] = [:]
        for (i, s) in JSON.objects(root, "scenes").enumerated() {
            guard let id = JSON.nonEmptyString(s, "id"), sceneIndexByID[id] == nil else { continue }
            sceneIndexByID[id] = scenes.count
            scenes.append(PendingScene(scene: StoryScene(
                id: id,
                index: JSON.int(s, "index") ?? i,
                name: JSON.string(s, "name") ?? "",
                number: JSON.int(s, "number") ?? 1,
                location: JSON.string(s, "location") ?? "",
                intExt: normalizedIntExt(JSON.string(s, "int_ext", "intExt")),
                dayNight: normalizedDayNight(JSON.string(s, "day_night", "dayNight")),
                estDurationSec: max(0, JSON.int(s, "est_duration_sec", "estDurationSec") ?? 0),
                notes: JSON.string(s, "notes") ?? ""
            ), projectId: JSON.nonEmptyString(s, "project_id", "projectId")))
        }

        // Shots
        var orphanShots: [StoryShot] = []
        var seenShots = Set<String>()
        for (i, sh) in JSON.objects(root, "shots").enumerated() {
            guard let id = JSON.nonEmptyString(sh, "id"), seenShots.insert(id).inserted else { continue }
            let takes: [StoryTake] = JSON.objects(sh, "takes").compactMap { t in
                guard let tid = JSON.nonEmptyString(t, "id") else { return nil }
                return StoryTake(id: tid, label: JSON.nonEmptyString(t, "label"),
                                 image: JSON.string(t, "image_id", "imageId").flatMap { EmbeddedImage.parse($0) })
            }
            let shot = StoryShot(
                id: id,
                index: JSON.int(sh, "index") ?? i,
                name: JSON.string(sh, "name") ?? "",
                types: JSON.strings(sh, "type", "types"),
                description: JSON.string(sh, "description") ?? "",
                detailedNotes: JSON.string(sh, "detailed_notes", "detailedNotes") ?? "",
                tags: JSON.strings(sh, "tags"),
                estDurationSec: max(0, JSON.int(sh, "est_duration_sec", "estDurationSec") ?? 5),
                status: JSON.nonEmptyString(sh, "status") ?? "Planned",
                thumb: JSON.string(sh, "thumb").flatMap { EmbeddedImage.parse($0) },
                videoRef: JSON.nonEmptyString(sh, "video_ref", "videoRef"),
                takes: takes
            )
            if let sid = JSON.nonEmptyString(sh, "scene_id", "sceneId"), let idx = sceneIndexByID[sid] {
                scenes[idx].scene.shots.append(shot)
            } else {
                orphanShots.append(shot)
            }
        }

        // Scripts
        var scriptsByProject: [String: [(Int, StoryScript)]] = [:]
        var orphanScripts: [StoryScript] = []
        for (i, s) in JSON.objects(root, "scripts").enumerated() {
            guard let id = JSON.nonEmptyString(s, "id") else { continue }
            let script = StoryScript(id: id, name: JSON.nonEmptyString(s, "name") ?? "Untitled Script",
                                     filename: JSON.string(s, "filename") ?? "", content: JSON.string(s, "content") ?? "")
            if let pid = JSON.nonEmptyString(s, "project_id", "projectId"), seenProjects.contains(pid) {
                scriptsByProject[pid, default: []].append((JSON.int(s, "index") ?? i, script))
            } else {
                orphanScripts.append(script)
            }
        }

        // Asset library (Mac + web): asset_lists / project_assets (camelCase aliases).
        var listsByProject: [String: [(Int, StoryAssetList)]] = [:]
        var assetsByList: [String: [(Int, StoryAsset)]] = [:]
        for (i, a) in JSON.objects(root, "project_assets", "projectAssets").enumerated() {
            guard let id = JSON.nonEmptyString(a, "id"), let lid = JSON.nonEmptyString(a, "list_id", "listId") else { continue }
            assetsByList[lid, default: []].append((JSON.int(a, "index") ?? i, StoryAsset(
                id: id, name: JSON.string(a, "name") ?? "", description: JSON.string(a, "description") ?? "",
                sceneIds: JSON.strings(a, "scene_ids", "sceneIds"),
                thumb: JSON.string(a, "thumb").flatMap { EmbeddedImage.parse($0) })))
        }
        for (i, l) in JSON.objects(root, "asset_lists", "assetLists").enumerated() {
            guard let id = JSON.nonEmptyString(l, "id"), let pid = JSON.nonEmptyString(l, "project_id", "projectId") else { continue }
            let assets = (assetsByList[id] ?? []).sorted { $0.0 < $1.0 }.map(\.1)
            listsByProject[pid, default: []].append((JSON.int(l, "index") ?? i,
                StoryAssetList(id: id, name: JSON.nonEmptyString(l, "name") ?? "Untitled", assets: assets)))
        }

        // Assemble
        var projectIndexByID: [String: Int] = [:]
        for (i, p) in projects.enumerated() { projectIndexByID[p.id] = i }
        var orphanScenes: [StoryScene] = []
        for var pending in scenes {
            pending.scene.shots = stableSorted(pending.scene.shots, by: \.index)
            if let pid = pending.projectId, let idx = projectIndexByID[pid] {
                projects[idx].scenes.append(pending.scene)
            } else {
                orphanScenes.append(pending.scene)
            }
        }
        for i in projects.indices {
            projects[i].scenes = stableSorted(projects[i].scenes, by: \.index)
            projects[i].scripts = (scriptsByProject[projects[i].id] ?? []).sorted { $0.0 < $1.0 }.map(\.1)
            projects[i].assetLists = (listsByProject[projects[i].id] ?? []).sorted { $0.0 < $1.0 }.map(\.1)
        }

        let hasOrphans = !orphanScenes.isEmpty || !orphanShots.isEmpty
        if hasOrphans || (projects.isEmpty && !orphanScripts.isEmpty) {
            var unassignedScene: StoryScene?
            if !orphanShots.isEmpty {
                unassignedScene = StoryScene(id: "unassigned", index: Int.max, name: unassignedName, number: 0,
                                             isUnassigned: true, shots: stableSorted(orphanShots, by: \.index))
            }
            if projects.count == 1 {
                projects[0].scenes.append(contentsOf: stableSorted(orphanScenes, by: \.index))
                if let s = unassignedScene { projects[0].scenes.append(s) }
                projects[0].scripts.append(contentsOf: orphanScripts)
            } else {
                var p = StoryProject(id: "unassigned", index: Int.max, title: unassignedName, isUnassigned: true)
                p.scenes = stableSorted(orphanScenes, by: \.index) + (unassignedScene.map { [$0] } ?? [])
                p.scripts = orphanScripts
                projects.append(p)
            }
        } else if projects.count == 1 {
            projects[0].scripts.append(contentsOf: orphanScripts)
        }

        return StoryDocument(projects: stableSorted(projects, by: \.index))
    }

    static func normalizedIntExt(_ s: String?) -> String {
        let u = (s ?? "").uppercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return u == "EXT" ? "EXT" : (u.isEmpty ? "INT" : (u == "INT" ? "INT" : u))
    }

    static func normalizedDayNight(_ s: String?) -> String {
        let u = (s ?? "").uppercased().trimmingCharacters(in: .whitespaces)
        return u.isEmpty ? "DAY" : u
    }

    static func stableSorted<T>(_ items: [T], by key: KeyPath<T, Int>) -> [T] {
        items.enumerated().sorted { a, b in
            let ka = a.element[keyPath: key], kb = b.element[keyPath: key]
            return ka != kb ? ka < kb : a.offset < b.offset
        }.map(\.element)
    }
}
