import SwiftUI

enum PromptExportFormat: String, CaseIterable {
    case raw
    case midjourney
    case stableDiffusion
    case comfyUI
    case dalle

    var displayName: String {
        switch self {
        case .raw: return "Raw Text"
        case .midjourney: return "Midjourney"
        case .stableDiffusion: return "Stable Diffusion"
        case .comfyUI: return "ComfyUI"
        case .dalle: return "DALL-E"
        }
    }

    var icon: String {
        switch self {
        case .raw: return "doc.plaintext"
        case .midjourney: return "sparkle"
        case .stableDiffusion: return "wand.and.stars"
        case .comfyUI: return "rectangle.connected.to.line.below"
        case .dalle: return "paintbrush"
        }
    }

    func format(entry: PromptEntry) -> String {
        let prompt = entry.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let negative = entry.blindPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = entry.generationInfo.model
        let ratio = entry.generationInfo.aspectRatio.rawValue

        switch self {
        case .raw:
            var parts = [prompt]
            if !negative.isEmpty { parts.append("Negative: \(negative)") }
            if model != "N/A" { parts.append("Model: \(model)") }
            if ratio != "N/A" { parts.append("Aspect: \(ratio)") }
            return parts.joined(separator: "\n")

        case .midjourney:
            var mjPrompt = "/imagine prompt: \(prompt)"
            if ratio != "N/A" { mjPrompt += " --ar \(ratio)" }
            if !negative.isEmpty { mjPrompt += " --no \(negative)" }
            return mjPrompt

        case .stableDiffusion:
            var result = prompt
            if !negative.isEmpty { result += "\nNegative prompt: \(negative)" }
            // Add common SD parameters
            result += "\nSteps: 20, Sampler: Euler a, CFG scale: 7"
            if ratio != "N/A" {
                let (w, h) = sdDimensions(for: ratio)
                result += ", Size: \(w)x\(h)"
            }
            if model != "N/A" { result += ", Model: \(model)" }
            return result

        case .comfyUI:
            // ComfyUI uses a JSON-like format
            var json: [String: Any] = ["positive": prompt]
            if !negative.isEmpty { json["negative"] = negative }
            if model != "N/A" { json["model"] = model }
            if ratio != "N/A" {
                let (w, h) = sdDimensions(for: ratio)
                json["width"] = w
                json["height"] = h
            }
            // Simple key-value output
            return json.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n")

        case .dalle:
            // DALL-E uses simple prompt, optional size
            var result = prompt
            if ratio != "N/A" {
                let size = dalleSize(for: ratio)
                result += "\n\nSize: \(size)"
            }
            return result
        }
    }

    private func sdDimensions(for ratio: String) -> (Int, Int) {
        switch ratio {
        case "1:1": return (512, 512)
        case "16:9": return (768, 432)
        case "9:16": return (432, 768)
        case "4:3": return (640, 480)
        case "3:4": return (480, 640)
        default: return (512, 512)
        }
    }

    private func dalleSize(for ratio: String) -> String {
        switch ratio {
        case "1:1": return "1024x1024"
        case "16:9": return "1792x1024"
        case "9:16": return "1024x1792"
        default: return "1024x1024"
        }
    }
}

struct PromptExportMenu: View {
    let entry: PromptEntry
    var onCopy: ((String) -> Void)?

    var body: some View {
        Menu {
            ForEach(PromptExportFormat.allCases, id: \.self) { format in
                Button {
                    let formatted = format.format(entry: entry)
                    ClipboardService.copyString(formatted)
                    onCopy?(format.displayName)
                } label: {
                    Label(format.displayName, systemImage: format.icon)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.on.square")
                    .font(.system(size: 11))
                Text("Export")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(Color.appMuted)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.appElevatedSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.appBorder, lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
