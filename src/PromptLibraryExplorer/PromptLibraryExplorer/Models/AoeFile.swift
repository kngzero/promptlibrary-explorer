import Foundation

/// Raw JSON structure of an .aoe (Art Official Elements) file.
struct AoeFile: Codable {
    let timestamp: Double?
    let image: AoeImageBlock?
    let analysis: PromptAnalysis?
    let model: String?
    let hint: String?
}

struct AoeImageBlock: Codable {
    let previewUrl: String?
    let base64: String?
    let mimeType: String?
}
