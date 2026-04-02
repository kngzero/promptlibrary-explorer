import Foundation
import UniformTypeIdentifiers

enum URLDropLoader {
    static func loadURLs(from providers: [NSItemProvider]) async -> [URL] {
        await withTaskGroup(of: URL?.self) { group in
            for provider in providers {
                group.addTask {
                    await loadURL(from: provider)
                }
            }

            var urls: [URL] = []
            for await url in group {
                if let url {
                    urls.append(url)
                }
            }
            return urls
        }
    }

    static func loadURL(from provider: NSItemProvider) async -> URL? {
        if let url = await loadURLObject(from: provider) {
            return url.standardizedFileURL
        }

        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let resolvedURL = resolvedFileURL(from: item)?.standardizedFileURL
                continuation.resume(returning: resolvedURL)
            }
        }
    }

    private static func loadURLObject(from provider: NSItemProvider) async -> URL? {
        guard provider.canLoadObject(ofClass: NSURL.self) else { return nil }

        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                continuation.resume(returning: (object as? NSURL) as URL?)
            }
        }
    }

    private static func resolvedFileURL(from item: NSSecureCoding?) -> URL? {
        switch item {
        case let url as URL:
            return url.isFileURL ? url : nil
        case let nsURL as NSURL:
            guard let url = nsURL as URL? else { return nil }
            return url.isFileURL ? url : nil
        case let data as Data:
            return fileURL(from: data)
        case let nsData as NSData:
            return fileURL(from: nsData as Data)
        case let string as String:
            return URL(string: string)?.isFileURL == true ? URL(string: string) : nil
        case let nsString as NSString:
            let string = nsString as String
            return URL(string: string)?.isFileURL == true ? URL(string: string) : nil
        default:
            return nil
        }
    }

    private static func fileURL(from data: Data) -> URL? {
        guard let string = String(data: data, encoding: .utf8) else { return nil }
        guard let url = URL(string: string), url.isFileURL else { return nil }
        return url
    }
}
