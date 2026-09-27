import Foundation

// MARK: - ComfyUI API graph editing (Re-run in ComfyUI)
//
// ComfyUIGraphParser (ImageMetadataParser.swift) only reads graphs and keeps
// its walker private, so this mirrors its conventions — API graph
// `{ id: { class_type, inputs } }`, links `["id", slot]`, the same sampler
// classes — to find the values to change: the sampler's seed (directly or via
// a linked RandomNoise / primitive node) and the text of the CLIPTextEncode
// node feeding the sampler's positive input (directly, through pass-through
// conditioning nodes, a guider, or a linked string primitive).

enum PromptComfyGraph {
    typealias Graph = [String: [String: Any]]

    struct EditResult {
        var graph: Graph
        /// "node.input" locations whose seed was replaced.
        var seedLocations: [String] = []
        /// "node.input" locations whose text was replaced.
        var promptLocations: [String] = []
    }

    static let samplerClasses: Set<String> = [
        "KSampler", "KSamplerAdvanced", "SamplerCustom", "SamplerCustomAdvanced",
        "KSampler (Efficient)", "KSampler Adv. (Efficient)", "KSamplerSDXLAdvanced",
    ]
    private static let textKeys = ["text", "text_g", "text_l", "prompt", "positive", "string", "value", "text_positive", "Text", "STRING"]
    private static let seedKeys = ["seed", "noise_seed"]

    /// Largest seed written: stays exact through JSON number round trips (2^50).
    static let maxSeed: UInt64 = 1 << 50

    // MARK: Parse / serialize

    /// Node map of an API graph (also accepts `{"prompt": {...}}`); nil for a UI workflow or bad JSON.
    static func parse(_ json: String) -> Graph? {
        guard let data = json.data(using: .utf8),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        if let wrapped = root["prompt"] as? [String: Any],
           wrapped.values.contains(where: { ($0 as? [String: Any])?["class_type"] != nil })
        {
            root = wrapped
        }
        var graph: Graph = [:]
        for (id, value) in root {
            if let node = value as? [String: Any], node["class_type"] is String { graph[id] = node }
        }
        return graph.isEmpty ? nil : graph
    }

    /// True for a UI workflow (`{ nodes: [...], links: [...] }`), which ComfyUI's `/prompt` can't queue.
    static func isUIWorkflow(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }
        return root["nodes"] is [Any]
    }

    /// `{"prompt": graph, "client_id": id}` for ComfyUI's `POST /prompt`.
    static func requestBody(graph: Graph, clientID: String) throws -> Data {
        let object: [String: Any] = ["prompt": graph, "client_id": clientID]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func randomSeed() -> UInt64 { UInt64.random(in: 0...maxSeed) }

    // MARK: Lookup

    private static func classType(_ graph: Graph, _ id: String) -> String { graph[id]?["class_type"] as? String ?? "" }
    private static func inputs(_ graph: Graph, _ id: String) -> [String: Any] { graph[id]?["inputs"] as? [String: Any] ?? [:] }

    static func link(_ value: Any?) -> String? {
        guard let array = value as? [Any], array.count == 2, array[1] is NSNumber else { return nil }
        if let s = array[0] as? String { return s }
        if let n = array[0] as? NSNumber { return n.stringValue }
        return nil
    }

    private static func sortedIDs(_ graph: Graph) -> [String] {
        graph.keys.sorted { a, b in
            switch (Int(a), Int(b)) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a < b
            }
        }
    }

    /// Sampler nodes: the known classes first, then any node with a positive /
    /// guider input and a seed or steps input.
    static func samplerIDs(in graph: Graph) -> [String] {
        let ordered = sortedIDs(graph)
        let known = ordered.filter { samplerClasses.contains(classType(graph, $0)) }
        let generic = ordered.filter { id in
            guard !known.contains(id) else { return false }
            let i = inputs(graph, id)
            let hasCond = i["positive"] != nil || i["guider"] != nil
            let samplerLike = i["seed"] != nil || i["noise_seed"] != nil || i["steps"] != nil || i["noise"] != nil
            return hasCond && samplerLike
        }
        return known + generic
    }

    /// Where the positive prompt text lives: (node, input key) pairs holding a string.
    static func positiveTextTargets(in graph: Graph) -> [(node: String, key: String)] {
        for sampler in samplerIDs(in: graph) {
            var source = inputs(graph, sampler)["positive"]
            if source == nil, let guider = link(inputs(graph, sampler)["guider"]), graph[guider] != nil {
                let g = inputs(graph, guider)
                source = g["positive"] ?? g["conditioning"]
            }
            guard let encoder = encoderNode(from: source, in: graph) else { continue }
            let targets = textTargets(of: encoder, in: graph)
            if !targets.isEmpty { return targets }
        }
        // No sampler to follow: the first text encoder in node order.
        for id in sortedIDs(graph) where classType(graph, id).hasPrefix("CLIPTextEncode") {
            let targets = textTargets(of: id, in: graph)
            if !targets.isEmpty { return targets }
        }
        return []
    }

    /// The current positive prompt (first target's text).
    static func positivePrompt(in graph: Graph) -> String? {
        guard let target = positiveTextTargets(in: graph).first else { return nil }
        return inputs(graph, target.node)[target.key] as? String
    }

    /// Follows a conditioning link to its text-encoder node, through
    /// pass-through nodes (ControlNetApplyAdvanced keeps positive/negative by
    /// slot, ConditioningSetArea / FluxGuidance take `conditioning`,
    /// ConditioningCombine takes `conditioning_1`).
    private static func encoderNode(from value: Any?, in graph: Graph) -> String? {
        var current = link(value)
        var slot = (value as? [Any]).flatMap { ($0.last as? NSNumber)?.intValue } ?? 0
        var visited = Set<String>()
        while let id = current, graph[id] != nil, visited.insert(id).inserted, visited.count < 64 {
            let cls = classType(graph, id)
            if cls.hasPrefix("CLIPTextEncode") || cls.contains("TextEncode") { return id }
            let i = inputs(graph, id)
            let next: Any?
            if i["positive"] != nil, i["negative"] != nil, link(i["positive"]) != nil {
                next = slot == 1 ? i["negative"] : i["positive"]
            } else {
                next = i["conditioning"] ?? i["conditioning_1"] ?? i["conditioning_to"] ?? i["positive"]
            }
            current = link(next)
            slot = (next as? [Any]).flatMap { ($0.last as? NSNumber)?.intValue } ?? 0
        }
        return nil
    }

    /// String inputs of an encoder holding the prompt; a linked text input is
    /// followed to the primitive / string node that holds it.
    private static func textTargets(of encoder: String, in graph: Graph) -> [(node: String, key: String)] {
        let i = inputs(graph, encoder)
        var targets: [(String, String)] = []
        for key in textKeys {
            guard let value = i[key] else { continue }
            if value is String {
                targets.append((encoder, key))
            } else if let upstream = link(value), graph[upstream] != nil {
                let u = inputs(graph, upstream)
                if let upstreamKey = textKeys.first(where: { u[$0] is String }) {
                    targets.append((upstream, upstreamKey))
                }
            }
        }
        return targets
    }

    /// Seed locations: each sampler's seed input, or the node it links to
    /// (RandomNoise via `noise`, a primitive via the seed input).
    static func seedTargets(in graph: Graph) -> [(node: String, key: String)] {
        var targets: [(String, String)] = []
        var seen = Set<String>()
        func add(_ node: String, _ key: String) {
            if seen.insert("\(node).\(key)").inserted { targets.append((node, key)) }
        }
        func numericKey(on node: String) -> String? {
            let i = inputs(graph, node)
            return (seedKeys + ["value", "int", "number", "Value"]).first { i[$0] is NSNumber }
        }
        for sampler in samplerIDs(in: graph) {
            let i = inputs(graph, sampler)
            var found = false
            for key in seedKeys {
                guard let value = i[key] else { continue }
                if value is NSNumber {
                    add(sampler, key); found = true
                } else if let upstream = link(value), graph[upstream] != nil, let upstreamKey = numericKey(on: upstream) {
                    add(upstream, upstreamKey); found = true
                }
            }
            if !found, let noise = link(i["noise"]), graph[noise] != nil, let key = numericKey(on: noise) {
                add(noise, key)
            }
        }
        return targets
    }

    // MARK: Edit

    /// Applies a new seed and/or positive prompt. Nil leaves that value alone.
    static func edit(_ graph: Graph, seed: UInt64?, positivePrompt: String?) -> EditResult {
        var result = EditResult(graph: graph)
        if let seed {
            for (node, key) in seedTargets(in: graph) {
                set(NSNumber(value: seed), node: node, key: key, in: &result.graph)
                result.seedLocations.append("\(node).\(key)")
            }
        }
        if let positivePrompt {
            for (node, key) in positiveTextTargets(in: graph) {
                set(positivePrompt, node: node, key: key, in: &result.graph)
                result.promptLocations.append("\(node).\(key)")
            }
        }
        return result
    }

    private static func set(_ value: Any, node: String, key: String, in graph: inout Graph) {
        guard var n = graph[node] else { return }
        var i = n["inputs"] as? [String: Any] ?? [:]
        i[key] = value
        n["inputs"] = i
        graph[node] = n
    }
}
