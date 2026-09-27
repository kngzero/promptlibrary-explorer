import Foundation

/// Pure HTML generation for the Quick Look preview extension. Every piece of
/// document text is HTML-escaped; colours are validated before reaching CSS;
/// only `data:image/...` URIs are emitted as image sources (no network, no files).
public enum PreviewHTML {
    // MARK: Documents

    public static func mood(_ m: MoodPreviewModel) -> String {
        var body = "<header>"
        body += "<p class=\"kind\">Mood Board</p>"
        body += "<h1>\(esc(m.title.isEmpty ? "Untitled board" : m.title))</h1>"
        if !m.subtitle.isEmpty { body += "<p class=\"subtitle\">\(esc(m.subtitle))</p>" }
        body += "</header>"
        if let uri = m.boardImageURI.flatMap(safeImageURI) {
            body += "<figure class=\"hero\"><img src=\"\(uri)\" alt=\"Mood board\"></figure>"
        } else {
            body += "<p class=\"empty\">No board preview available.</p>"
        }
        var stats: [PreviewField] = [
            .init("Images", String(m.imageCount)),
            .init("Tiles", String(m.tileCount)),
            .init("Layout", m.layout.capitalized),
        ]
        if let canvas = m.canvas { stats.append(.init("Canvas", canvas)) }
        if m.isLegacyArchive { stats.append(.init("Format", "Legacy archive")) }
        body += fieldList(stats, className: "stats")
        let swatches = m.palette.compactMap(safeHex)
        if !swatches.isEmpty {
            body += "<section><h2>Palette</h2><ul class=\"palette\">"
            for hex in swatches {
                body += "<li><span class=\"swatch\" style=\"background:\(hex)\"></span><code>\(hex.uppercased())</code></li>"
            }
            body += "</ul></section>"
        }
        return page(title: m.title, body: body)
    }

    public static func story(_ s: StoryPreviewModel) -> String {
        var body = ""
        if s.projects.count > 1 {
            body += "<header><p class=\"kind\">Story</p><h1>\(esc(s.fileTitle))</h1>"
            body += "<p class=\"subtitle\">\(s.projects.count) projects</p></header>"
            body += "<nav class=\"toc\"><ol>"
            for (i, p) in s.projects.enumerated() {
                body += "<li><a href=\"#project-\(i)\">\(esc(p.title))</a></li>"
            }
            body += "</ol></nav>"
        }
        if s.projects.isEmpty {
            body += "<header><p class=\"kind\">Story</p><h1>\(esc(s.fileTitle))</h1></header>"
            body += "<p class=\"empty\">This file contains no projects.</p>"
        }
        for (i, p) in s.projects.enumerated() {
            body += "<article class=\"project\" id=\"project-\(i)\">"
            body += "<header><p class=\"kind\">Story Project\(p.code.isEmpty ? "" : " · \(esc(p.code))")</p>"
            body += "<h1>\(esc(p.title))</h1>"
            if let logline = p.logline, !logline.isEmpty { body += "<p class=\"subtitle\">\(esc(logline))</p>" }
            body += "</header>"
            if let uri = p.contactSheetURI.flatMap(safeImageURI) {
                body += "<figure class=\"hero\"><img src=\"\(uri)\" alt=\"Contact sheet\"></figure>"
            }
            var info = p.info
            if !p.status.isEmpty { info.insert(.init("Status", p.status), at: 0) }
            body += fieldList(info, className: "stats")
            if let notes = p.notes, !notes.isEmpty {
                body += "<section><h2>Production notes</h2><p class=\"prose\">\(esc(notes))</p></section>"
            }
            if p.scenes.isEmpty {
                body += "<p class=\"empty\">No scenes yet.</p>"
            }
            for scene in p.scenes {
                body += "<section class=\"scene\"><h2>\(esc(scene.heading))"
                if scene.durationSec > 0 { body += " <span class=\"muted\">\(duration(scene.durationSec))</span>" }
                body += "</h2>"
                if let slug = scene.slugline, !slug.isEmpty { body += "<p class=\"slug\">\(esc(slug))</p>" }
                if !scene.notes.isEmpty { body += "<p class=\"prose muted\">\(esc(scene.notes))</p>" }
                if scene.shots.isEmpty { body += "<p class=\"empty\">No shots.</p>" }
                body += "<ol class=\"shots\">"
                for shot in scene.shots {
                    body += "<li class=\"shot\">"
                    if let uri = shot.thumbURI.flatMap(safeImageURI) {
                        body += "<img class=\"thumb\" src=\"\(uri)\" alt=\"\">"
                    } else {
                        body += "<div class=\"thumb placeholder\"></div>"
                    }
                    body += "<div class=\"shot-text\"><p class=\"shot-title\"><span class=\"num\">\(esc(shot.label))</span> \(esc(shot.name))</p>"
                    var meta: [String] = []
                    if !shot.types.isEmpty { meta.append(shot.types.joined(separator: ", ")) }
                    if shot.durationSec > 0 { meta.append(duration(shot.durationSec)) }
                    if !shot.status.isEmpty { meta.append(shot.status) }
                    if !meta.isEmpty { body += "<p class=\"meta\">\(esc(meta.joined(separator: " · ")))</p>" }
                    if !shot.description.isEmpty { body += "<p class=\"desc\">\(esc(shot.description))</p>" }
                    if !shot.tags.isEmpty {
                        body += "<p class=\"tags\">" + shot.tags.map { "<span>\(esc($0))</span>" }.joined() + "</p>"
                    }
                    body += "</div></li>"
                }
                body += "</ol></section>"
            }
            body += "</article>"
        }
        if s.omittedThumbCount > 0 {
            body += "<p class=\"empty\">\(s.omittedThumbCount) more shot thumbnails not shown in this preview.</p>"
        }
        return page(title: s.projects.count == 1 ? s.projects[0].title : s.fileTitle, body: body)
    }

    public static func prompt(_ p: PromptPreviewModel) -> String {
        var body = "<header><p class=\"kind\">\(esc(p.kindName))</p><h1>\(esc(p.title))</h1>"
        if let d = p.shortDescription, !d.isEmpty { body += "<p class=\"subtitle\">\(esc(d))</p>" }
        body += "</header>"
        let images = p.imageURIs.compactMap(safeImageURI)
        if images.count == 1 {
            body += "<figure class=\"hero\"><img src=\"\(images[0])\" alt=\"\"></figure>"
        } else if !images.isEmpty {
            body += "<div class=\"grid\">" + images.map { "<img src=\"\($0)\" alt=\"\">" }.joined() + "</div>"
        }
        if p.totalImageCount > images.count {
            body += "<p class=\"empty\">\(p.totalImageCount - images.count) more image(s) not shown.</p>"
        }
        if !p.prompt.isEmpty {
            body += "<section><h2>Prompt</h2><blockquote class=\"prompt\">\(esc(p.prompt))</blockquote></section>"
        }
        if !p.generation.isEmpty {
            body += "<section><h2>Generation</h2>\(fieldList(p.generation, className: "fields"))</section>"
        }
        if !p.analysis.isEmpty {
            body += "<section><h2>Analysis</h2>\(fieldList(p.analysis, className: "fields"))</section>"
        }
        let refs = p.referenceImageURIs.compactMap(safeImageURI)
        if !refs.isEmpty {
            body += "<section><h2>Reference images</h2><div class=\"refs\">"
            body += refs.map { "<img src=\"\($0)\" alt=\"\">" }.joined()
            body += "</div></section>"
        }
        return page(title: p.title, body: body)
    }

    public static func message(title: String, detail: String) -> String {
        page(title: title, body: "<header><h1>\(esc(title))</h1></header><p class=\"empty\">\(esc(detail))</p>")
    }

    // MARK: Helpers

    public static func esc(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }

    /// "#RGB", "#RRGGBB" or "#RRGGBBAA" (a leading "#" is added if missing); nil otherwise.
    public static func safeHex(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if !s.hasPrefix("#") { s = "#" + s }
        let digits = s.dropFirst()
        guard [3, 6, 8].contains(digits.count), digits.allSatisfy(\.isHexDigit) else { return nil }
        return s
    }

    /// Only base64 `data:image/<type>;base64,` URIs pass (they cannot break out of the attribute).
    public static func safeImageURI(_ uri: String) -> String? {
        guard uri.hasPrefix("data:image/"), let comma = uri.firstIndex(of: ",") else { return nil }
        let header = uri[..<comma]
        guard header.hasSuffix(";base64"),
              header.dropFirst(5).allSatisfy({ $0.isLetter || $0.isNumber || "/+.-;".contains($0) }),
              uri[uri.index(after: comma)...].utf8.allSatisfy({ b in
                  (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39)
                      || b == 0x2B || b == 0x2F || b == 0x3D
              })
        else { return nil }
        return uri
    }

    public static func duration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return s >= 60 ? "\(s / 60)m \(String(format: "%02d", s % 60))s" : "\(s)s"
    }

    static func fieldList(_ fields: [PreviewField], className: String) -> String {
        guard !fields.isEmpty else { return "" }
        var out = "<dl class=\"\(className)\">"
        for f in fields { out += "<div><dt>\(esc(f.label))</dt><dd>\(esc(f.value))</dd></div>" }
        return out + "</dl>"
    }

    static func page(title: String, body: String) -> String {
        """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <meta name="color-scheme" content="light dark">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
        <title>\(esc(title))</title>
        <style>\(css)</style></head>
        <body><main>\(body)</main></body></html>
        """
    }

    static let css = """
    :root { color-scheme: light dark; --bg:#ffffff; --fg:#1d1d1f; --muted:#6e6e73; --card:#f5f5f7;
      --line:rgba(0,0,0,.10); --accent:#0a64d8; --shadow:0 1px 3px rgba(0,0,0,.12), 0 6px 20px rgba(0,0,0,.06); }
    @media (prefers-color-scheme: dark) { :root { --bg:#1e1e1e; --fg:#f5f5f7; --muted:#a1a1a6; --card:#2a2a2c;
      --line:rgba(255,255,255,.12); --accent:#4ea1ff; --shadow:0 1px 3px rgba(0,0,0,.5); } }
    * { box-sizing:border-box; }
    html,body { margin:0; background:var(--bg); color:var(--fg); }
    body { font:14px/1.5 -apple-system, BlinkMacSystemFont, system-ui, "Helvetica Neue", sans-serif;
      -webkit-font-smoothing:antialiased; }
    main { max-width:960px; margin:0 auto; padding:28px 32px 48px; }
    header { margin-bottom:18px; }
    .kind { margin:0 0 2px; font-size:11px; font-weight:600; letter-spacing:.06em; text-transform:uppercase; color:var(--muted); }
    h1 { margin:0; font-size:26px; line-height:1.2; font-weight:700; letter-spacing:-.01em; }
    h2 { margin:28px 0 10px; font-size:15px; font-weight:650; }
    .subtitle { margin:6px 0 0; font-size:15px; color:var(--muted); }
    .muted { color:var(--muted); font-weight:400; }
    .empty { color:var(--muted); font-style:italic; }
    figure.hero { margin:0 0 18px; }
    figure.hero img, .grid img { display:block; width:100%; height:auto; border-radius:10px; box-shadow:var(--shadow); }
    .grid { display:grid; grid-template-columns:repeat(auto-fill, minmax(260px, 1fr)); gap:12px; margin-bottom:18px; }
    .refs { display:flex; flex-wrap:wrap; gap:8px; }
    .refs img { height:96px; width:auto; border-radius:6px; border:1px solid var(--line); }
    dl { margin:0; }
    dl.stats { display:flex; flex-wrap:wrap; gap:8px; }
    dl.stats div { background:var(--card); border-radius:8px; padding:6px 12px; }
    dl.stats dt { font-size:11px; color:var(--muted); }
    dl.stats dd { margin:0; font-weight:600; }
    dl.fields div { display:grid; grid-template-columns:150px 1fr; gap:12px; padding:6px 0; border-top:1px solid var(--line); }
    dl.fields div:first-child { border-top:none; }
    dl.fields dt { color:var(--muted); }
    dl.fields dd { margin:0; white-space:pre-wrap; }
    blockquote.prompt { margin:0; padding:14px 16px; background:var(--card); border-radius:10px;
      border-left:3px solid var(--accent); white-space:pre-wrap; font-size:14px; line-height:1.6; }
    .prose { white-space:pre-wrap; margin:4px 0 10px; }
    ul.palette { list-style:none; margin:0; padding:0; display:flex; flex-wrap:wrap; gap:12px; }
    ul.palette li { display:flex; flex-direction:column; align-items:center; gap:4px; }
    .swatch { width:56px; height:56px; border-radius:10px; border:1px solid var(--line); box-shadow:var(--shadow); }
    ul.palette code { font:11px ui-monospace, SFMono-Regular, Menlo, monospace; color:var(--muted); }
    nav.toc ol { margin:0 0 12px; padding-left:20px; }
    nav.toc a { color:var(--accent); text-decoration:none; }
    article.project + article.project { margin-top:40px; padding-top:28px; border-top:1px solid var(--line); }
    .scene h2 { border-bottom:1px solid var(--line); padding-bottom:6px; }
    .slug { margin:0 0 6px; font:600 12px ui-monospace, SFMono-Regular, Menlo, monospace; letter-spacing:.03em; color:var(--muted); }
    ol.shots { list-style:none; margin:0; padding:0; }
    li.shot { display:flex; gap:14px; padding:10px 0; border-top:1px solid var(--line); }
    li.shot:first-child { border-top:none; }
    .thumb { flex:0 0 160px; width:160px; height:90px; object-fit:cover; border-radius:6px; background:var(--card); }
    .shot-text { min-width:0; }
    .shot-text p { margin:0; }
    .shot-title { font-weight:600; }
    .num { display:inline-block; min-width:2.4em; color:var(--accent); font-variant-numeric:tabular-nums; }
    .meta { font-size:12px; color:var(--muted); }
    .desc { margin-top:4px !important; white-space:pre-wrap; }
    .tags { margin-top:6px !important; display:flex; flex-wrap:wrap; gap:4px; }
    .tags span { font-size:11px; padding:1px 8px; border-radius:999px; background:var(--card); color:var(--muted); }
    """
}
