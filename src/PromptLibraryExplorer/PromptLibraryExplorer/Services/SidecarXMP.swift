import Foundation

// MARK: - Values

/// The curation an XMP sidecar carries.
struct XMPSidecarValues: Equatable, Sendable {
    /// xmp:Rating, 0–5 (nil = not present). A Bridge-style -1 is read as a reject flag.
    var rating: Int?
    /// xmp:Label colour name ("Red" …).
    var label: String?
    /// dc:subject keywords.
    var subjects: [String] = []
    /// dc:description (the positive prompt).
    var descriptionText: String?
    /// plx:Flag ("pick" / "reject").
    var flag: FileFlag?
    /// plx:NegativePrompt.
    var negativePrompt: String?

    /// The Finder label an xmp:Label names (English colour names, as Lightroom writes).
    var finderLabel: FinderLabel? {
        guard let label = label?.trimmingCharacters(in: .whitespaces).lowercased(), !label.isEmpty else { return nil }
        switch label {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "blue": return .blue
        case "purple": return .purple
        case "gray", "grey": return .gray
        default: return nil
        }
    }

    static func labelName(for label: FinderLabel) -> String? {
        switch label {
        case .none: return nil
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .gray: return "Gray"
        }
    }
}

// MARK: - Codec

/// Reads and writes Lightroom / Bridge compatible XMP sidecars. Writing updates only the
/// properties the app owns (xmp:Rating, xmp:Label, dc:subject, dc:description and the
/// plx: namespace); everything else in an existing sidecar — Lightroom develop settings,
/// other apps' fields — is kept.
enum XMPSidecarCodec {
    static let nsMeta = "adobe:ns:meta/"
    static let nsRDF = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    static let nsXMP = "http://ns.adobe.com/xap/1.0/"
    static let nsDC = "http://purl.org/dc/elements/1.1/"
    static let nsPLX = "http://ns.artofficial.app/promptlibrary/1.0/"

    // MARK: Read

    static func parse(_ data: Data) -> XMPSidecarValues? {
        guard let document = try? XMLDocument(data: data, options: []) else { return nil }
        let descriptions = elements(in: document, uri: nsRDF, localName: "Description")
        guard !descriptions.isEmpty else { return nil }
        var values = XMPSidecarValues()
        for description in descriptions {
            for attribute in description.attributes ?? [] {
                guard let (uri, local) = resolve(attribute.name, in: description) else { continue }
                let text = attribute.stringValue ?? ""
                assign(uri: uri, local: local, text: text, element: nil, into: &values)
            }
            for child in description.children ?? [] {
                guard let element = child as? XMLElement, let (uri, local) = resolve(element.name, in: element) else { continue }
                assign(uri: uri, local: local, text: element.stringValue ?? "", element: element, into: &values)
            }
        }
        return values
    }

    private static func assign(uri: String, local: String, text: String, element: XMLElement?, into values: inout XMPSidecarValues) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (uri, local) {
        case (nsXMP, "Rating"):
            if let rating = Int(trimmed) ?? Double(trimmed).map({ Int($0.rounded()) }) {
                if rating < 0 {
                    values.rating = 0
                    if values.flag == nil { values.flag = .reject }
                } else {
                    values.rating = min(5, rating)
                }
            }
        case (nsXMP, "Label"):
            values.label = trimmed.isEmpty ? nil : trimmed
        case (nsDC, "subject"):
            if let element {
                values.subjects = listItems(of: element)
            } else if !trimmed.isEmpty {
                values.subjects = [trimmed]
            }
        case (nsDC, "description"):
            let text = element.map { listItems(of: $0).first ?? trimmedText($0) } ?? trimmed
            values.descriptionText = text.isEmpty ? nil : text
        case (nsPLX, "Flag"):
            switch trimmed.lowercased() {
            case "pick", "1": values.flag = .pick
            case "reject", "-1": values.flag = .reject
            default: values.flag = .unflagged
            }
        case (nsPLX, "NegativePrompt"):
            values.negativePrompt = trimmed.isEmpty ? nil : text
        default:
            break
        }
    }

    /// rdf:li texts inside an rdf:Bag / rdf:Seq / rdf:Alt container.
    private static func listItems(of element: XMLElement) -> [String] {
        var items: [String] = []
        for container in element.children ?? [] {
            guard let container = container as? XMLElement else { continue }
            for item in container.children ?? [] {
                guard let item = item as? XMLElement,
                      let (uri, local) = resolve(item.name, in: item), uri == nsRDF, local == "li"
                else { continue }
                let text = (item.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { items.append(text) }
            }
        }
        return items
    }

    private static func trimmedText(_ element: XMLElement) -> String {
        (element.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Write

    /// Renders `values` into `existing` (a sidecar already on disk, possibly written by
    /// Lightroom) or a fresh packet.
    static func render(_ values: XMPSidecarValues, updating existing: Data?) -> Data {
        let document: XMLDocument
        if let existing, let parsed = try? XMLDocument(data: existing, options: []),
           !elements(in: parsed, uri: nsRDF, localName: "RDF").isEmpty
        {
            document = parsed
        } else {
            document = freshDocument()
        }

        let rdf = elements(in: document, uri: nsRDF, localName: "RDF").first!
        var descriptions = elements(in: document, uri: nsRDF, localName: "Description")
        if descriptions.isEmpty {
            let description = XMLElement(name: prefixed("rdf", "Description"), uri: nsRDF)
            description.addAttribute(XMLNode.attribute(withName: prefixed("rdf", "about"), uri: nsRDF, stringValue: "") as! XMLNode)
            rdf.addChild(description)
            descriptions = [description]
        }

        // Drop our properties wherever they are.
        for description in descriptions {
            for attribute in description.attributes ?? [] {
                guard let name = attribute.name, let (uri, local) = resolve(name, in: description), isOwned(uri: uri, local: local) else { continue }
                description.removeAttribute(forName: name)
            }
            for child in (description.children ?? []).reversed() {
                guard let element = child as? XMLElement, let (uri, local) = resolve(element.name, in: element),
                      isOwned(uri: uri, local: local)
                else { continue }
                element.detach()
            }
        }

        let target = descriptions[0]
        let xmp = prefix(for: nsXMP, preferred: "xmp", on: target)
        let dc = prefix(for: nsDC, preferred: "dc", on: target)
        let plx = prefix(for: nsPLX, preferred: "plx", on: target)
        let rdfPrefix = prefix(for: nsRDF, preferred: "rdf", on: target)

        target.addAttribute(XMLNode.attribute(withName: "\(xmp):Rating", uri: nsXMP, stringValue: String(max(0, min(5, values.rating ?? 0)))) as! XMLNode)
        if let label = values.label, !label.isEmpty {
            target.addAttribute(XMLNode.attribute(withName: "\(xmp):Label", uri: nsXMP, stringValue: label) as! XMLNode)
        }
        if let flag = values.flag, flag != .unflagged {
            target.addAttribute(XMLNode.attribute(withName: "\(plx):Flag", uri: nsPLX, stringValue: flag == .pick ? "pick" : "reject") as! XMLNode)
        }
        if !values.subjects.isEmpty {
            let subject = XMLElement(name: "\(dc):subject", uri: nsDC)
            let bag = XMLElement(name: "\(rdfPrefix):Bag", uri: nsRDF)
            for keyword in values.subjects {
                bag.addChild(XMLElement(name: "\(rdfPrefix):li", stringValue: keyword))
            }
            subject.addChild(bag)
            target.addChild(subject)
        }
        if let text = values.descriptionText, !text.isEmpty {
            let description = XMLElement(name: "\(dc):description", uri: nsDC)
            let alt = XMLElement(name: "\(rdfPrefix):Alt", uri: nsRDF)
            let item = XMLElement(name: "\(rdfPrefix):li", stringValue: text)
            item.addAttribute(XMLNode.attribute(withName: "xml:lang", stringValue: "x-default") as! XMLNode)
            alt.addChild(item)
            description.addChild(alt)
            target.addChild(description)
        }
        if let negative = values.negativePrompt, !negative.isEmpty {
            target.addChild(XMLElement(name: "\(plx):NegativePrompt", stringValue: negative))
        }

        return document.xmlData(options: [.nodePrettyPrint, .nodeCompactEmptyElement])
    }

    private static func isOwned(uri: String, local: String) -> Bool {
        switch uri {
        case nsXMP: return local == "Rating" || local == "Label"
        case nsDC: return local == "subject" || local == "description"
        case nsPLX: return true
        default: return false
        }
    }

    private static func freshDocument() -> XMLDocument {
        let meta = XMLElement(name: "x:xmpmeta")
        meta.addNamespace(XMLNode.namespace(withName: "x", stringValue: nsMeta) as! XMLNode)
        meta.addAttribute(XMLNode.attribute(withName: "x:xmptk", uri: nsMeta, stringValue: "PromptLibrary Explorer") as! XMLNode)
        let rdf = XMLElement(name: "rdf:RDF")
        rdf.addNamespace(XMLNode.namespace(withName: "rdf", stringValue: nsRDF) as! XMLNode)
        let description = XMLElement(name: "rdf:Description")
        description.addAttribute(XMLNode.attribute(withName: "rdf:about", uri: nsRDF, stringValue: "") as! XMLNode)
        rdf.addChild(description)
        meta.addChild(rdf)
        let document = XMLDocument(rootElement: meta)
        document.characterEncoding = "UTF-8"
        document.version = "1.0"
        return document
    }

    private static func prefixed(_ prefix: String, _ local: String) -> String { "\(prefix):\(local)" }

    /// The prefix bound to `uri` in scope of `element`, declaring `preferred` when none is.
    private static func prefix(for uri: String, preferred: String, on element: XMLElement) -> String {
        var node: XMLNode? = element
        while let current = node as? XMLElement {
            for namespace in current.namespaces ?? [] where namespace.stringValue == uri {
                if let name = namespace.name, !name.isEmpty { return name }
            }
            node = current.parent
        }
        var candidate = preferred
        var counter = 2
        while let bound = element.resolveNamespace(forName: "\(candidate):x"), bound.stringValue != uri {
            candidate = "\(preferred)\(counter)"
            counter += 1
        }
        element.addNamespace(XMLNode.namespace(withName: candidate, stringValue: uri) as! XMLNode)
        return candidate
    }

    // MARK: Namespaces

    /// (namespace URI, local name) of a qualified name in scope of `element`.
    private static func resolve(_ qualifiedName: String?, in element: XMLElement) -> (String, String)? {
        guard let qualifiedName, let colon = qualifiedName.firstIndex(of: ":") else { return nil }
        let prefix = String(qualifiedName[..<colon])
        let local = String(qualifiedName[qualifiedName.index(after: colon)...])
        if prefix == "xml" { return ("http://www.w3.org/XML/1998/namespace", local) }
        var node: XMLNode? = element
        while let current = node as? XMLElement {
            for namespace in current.namespaces ?? [] where namespace.name == prefix {
                if let uri = namespace.stringValue { return (uri, local) }
            }
            node = current.parent
        }
        return nil
    }

    private static func elements(in document: XMLDocument, uri: String, localName: String) -> [XMLElement] {
        guard let root = document.rootElement() else { return [] }
        var result: [XMLElement] = []
        var stack: [XMLElement] = [root]
        while let element = stack.popLast() {
            if let (elementURI, local) = resolve(element.name, in: element), elementURI == uri, local == localName {
                result.append(element)
            }
            let children = (element.children ?? []).compactMap { $0 as? XMLElement }
            stack.append(contentsOf: children.reversed())
        }
        return result
    }
}

// MARK: - Locating sidecars

/// Where a file's sidecar lives. Lightroom / Bridge convention: same basename with
/// `.xmp` (`IMG_1.png` → `IMG_1.xmp`). When another file in the folder shares the
/// basename (`IMG_1.png` + `IMG_1.jpg`) that name is ambiguous, so the full name is
/// used instead (`IMG_1.png.xmp`, as darktable does). Originals are never modified.
enum SidecarLocator {
    static func isSidecarName(_ name: String) -> Bool {
        (name as NSString).pathExtension.lowercased() == "xmp"
    }

    /// Files that can have a sidecar: images, videos and audio.
    static func supportsSidecar(_ name: String) -> Bool {
        !isSidecarName(name)
            && (FileHelpers.isImageFile(name) || FileHelpers.isVideoFile(name) || FileHelpers.isAudioFile(name))
    }

    /// True when another non-sidecar item in the folder shares `fileURL`'s basename.
    static func hasBasenameCollision(_ fileURL: URL, siblings: [String]) -> Bool {
        let name = fileURL.lastPathComponent
        let base = (name as NSString).deletingPathExtension.lowercased()
        return siblings.contains { sibling in
            sibling.caseInsensitiveCompare(name) != .orderedSame
                && !isSidecarName(sibling)
                && (sibling as NSString).deletingPathExtension.lowercased() == base
        }
    }

    static func siblingNames(of fileURL: URL, fileManager: FileManager = .default) -> [String] {
        (try? fileManager.contentsOfDirectory(atPath: fileURL.deletingLastPathComponent().path)) ?? []
    }

    static func basenameSidecarURL(for fileURL: URL) -> URL {
        fileURL.deletingPathExtension().appendingPathExtension("xmp")
    }

    static func fullNameSidecarURL(for fileURL: URL) -> URL {
        fileURL.appendingPathExtension("xmp")
    }

    /// The sidecar that belongs to `fileURL`, if one exists.
    static func existingSidecar(for fileURL: URL, siblings: [String]? = nil, fileManager: FileManager = .default) -> URL? {
        let full = fullNameSidecarURL(for: fileURL)
        if fileManager.fileExists(atPath: full.path) { return full }
        let names = siblings ?? siblingNames(of: fileURL, fileManager: fileManager)
        guard !hasBasenameCollision(fileURL, siblings: names) else { return nil }
        let basename = basenameSidecarURL(for: fileURL)
        return fileManager.fileExists(atPath: basename.path) ? basename : nil
    }

    /// Where to write `fileURL`'s sidecar: the existing one, else the convention.
    static func sidecarURL(for fileURL: URL, siblings: [String]? = nil, fileManager: FileManager = .default) -> URL {
        let names = siblings ?? siblingNames(of: fileURL, fileManager: fileManager)
        if let existing = existingSidecar(for: fileURL, siblings: names, fileManager: fileManager) { return existing }
        return hasBasenameCollision(fileURL, siblings: names) ? fullNameSidecarURL(for: fileURL) : basenameSidecarURL(for: fileURL)
    }
}

// MARK: - Following files

/// A sidecar moved to the Trash with its file, kept in the file's undo record.
struct SidecarTrashRecord: Equatable, Sendable {
    let trashedURL: URL
    let originalURL: URL
}

/// Keeps sidecars next to their files through renames, moves, trash and undo. Called
/// from the view model's metadata migration hooks, after the file itself has moved.
struct SidecarFollower {
    var fileManager: FileManager = .default
    /// Moves an item to the Trash and returns where it went (injectable for tests).
    var trash: (URL) throws -> URL = { url in
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return (resulting as URL?) ?? url
    }

    /// The file at `oldURL` is now at `newURL`: bring its sidecar along. Returns the new
    /// sidecar location, or nil when there was nothing (or nothing safe) to move.
    @discardableResult
    func fileDidMove(from oldURL: URL, to newURL: URL) -> URL? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: newURL.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              !SidecarLocator.isSidecarName(newURL.lastPathComponent),
              let sidecar = SidecarLocator.existingSidecar(for: oldURL, fileManager: fileManager)
        else { return nil }
        let destination = freeDestination(for: newURL, movingFrom: sidecar)
        guard let destination, destination.path != sidecar.path else { return nil }
        do {
            try fileManager.moveItem(at: sidecar, to: destination)
            return destination
        } catch {
            NSLog("PromptLibraryExplorer: couldn't move sidecar %@: %@", sidecar.path, error.localizedDescription)
            return nil
        }
    }

    /// The file at `fileURL` was trashed: trash its sidecar too.
    func fileWasTrashed(_ fileURL: URL) -> SidecarTrashRecord? {
        guard !SidecarLocator.isSidecarName(fileURL.lastPathComponent),
              let sidecar = SidecarLocator.existingSidecar(for: fileURL, fileManager: fileManager)
        else { return nil }
        do {
            let trashed = try trash(sidecar)
            return SidecarTrashRecord(trashedURL: trashed, originalURL: sidecar)
        } catch {
            NSLog("PromptLibraryExplorer: couldn't trash sidecar %@: %@", sidecar.path, error.localizedDescription)
            return nil
        }
    }

    /// The file came back from the Trash at `fileURL`: put its sidecar back beside it.
    @discardableResult
    func restore(_ record: SidecarTrashRecord, besideFileAt fileURL: URL) -> URL? {
        guard fileManager.fileExists(atPath: record.trashedURL.path) else { return nil }
        let destination = freeDestination(for: fileURL, movingFrom: record.trashedURL)
            ?? (fileManager.fileExists(atPath: record.originalURL.path) ? nil : record.originalURL)
        guard let destination else { return nil }
        do {
            try fileManager.moveItem(at: record.trashedURL, to: destination)
            return destination
        } catch {
            NSLog("PromptLibraryExplorer: couldn't restore sidecar %@: %@", record.trashedURL.path, error.localizedDescription)
            return nil
        }
    }

    /// The conventional sidecar name for `fileURL` if free, else the full-name form, else nil.
    private func freeDestination(for fileURL: URL, movingFrom source: URL) -> URL? {
        let siblings = SidecarLocator.siblingNames(of: fileURL, fileManager: fileManager)
            .filter { $0 != source.lastPathComponent || source.deletingLastPathComponent().path != fileURL.deletingLastPathComponent().path }
        let preferred = SidecarLocator.hasBasenameCollision(fileURL, siblings: siblings)
            ? SidecarLocator.fullNameSidecarURL(for: fileURL)
            : SidecarLocator.basenameSidecarURL(for: fileURL)
        for candidate in [preferred, SidecarLocator.fullNameSidecarURL(for: fileURL)] {
            if candidate.path == source.path || !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
