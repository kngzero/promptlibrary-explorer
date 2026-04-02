import Foundation

/// Raw JSON structure of a .plib (Prompt Library) file.
struct PlibFile: Codable {
    let prompt: String?
    let blindPrompt: String?
    let hint: String?
    let images: [String]?
    let referenceImages: [String]?
    let generationInfo: GenerationInfo?
    let analysis: PromptAnalysis?
}
