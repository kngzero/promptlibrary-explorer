import ArtOfficialFormats
import SwiftUI

/// Details-panel section for a Mood board or Story project. Sits at the top of the
/// metadata pane (the rest of the panel — rating, flag, tags, file info — stays as is).
struct ArtOfficialDocumentDetailView: View {
    @Environment(ExplorerViewModel.self) private var vm
    let document: ArtOfficialDocument
    let fileURL: URL
    /// Lightbox sidebar: skip the long lists (images, outline, scripts).
    var compact = false

    @State private var selectedProjectID: String?

    private var item: FileEntry { FileEntry(url: fileURL, isDirectory: false) }

    var body: some View {
        switch document {
        case .moodboard(let board):
            moodboardSections(board)
        case .story(let story):
            storySections(story)
        }
    }

    // MARK: - Mood

    @ViewBuilder
    private func moodboardSections(_ board: Moodboard) -> some View {
        ArtOfficialCard(title: nil) {
            HStack(alignment: .top, spacing: AppSpacing.sm) {
                Image(systemName: "square.grid.3x3.square")
                    .font(.appCallout)
                    .foregroundStyle(Color.badgeMoodText)
                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                    Text(board.title.isEmpty ? "Untitled Board" : board.title)
                        .font(.appHeadline)
                        .foregroundStyle(Color.appPrimaryText)
                        .textSelection(.enabled)
                    if !board.subtitle.isEmpty {
                        Text(board.subtitle)
                            .font(.appCaption)
                            .foregroundStyle(Color.appMuted)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
                moodActionsMenu(board)
            }
            ownerAppButton(kind: .moodboard)
        }

        ArtOfficialCard(title: "Board") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: AppSpacing.md) {
                statCell("Layout", layoutLabel(board))
                statCell("Columns", "\(board.columns)")
                statCell("Assets", "\(board.assets.count)")
                statCell("Tiles", tileLabel(board))
            }
            if board.isLegacyArchive {
                Text("Legacy ZIP board")
                    .font(.appFootnote)
                    .foregroundStyle(Color.appMuted)
            }
        }

        let palette = ArtOfficialTextExport.normalizedPalette(board.palette)
        if !palette.isEmpty {
            ArtOfficialCard(title: "Palette") {
                HStack(alignment: .center, spacing: AppSpacing.sm) {
                    ForEach(Array(palette.enumerated()), id: \.offset) { _, hex in
                        Button {
                            ClipboardService.copyString(hex)
                            vm.showToast("Copied \(hex)", type: .success)
                        } label: {
                            RoundedRectangle(cornerRadius: AppRadius.sm)
                                .fill(Color(hex: hex))
                                .frame(width: 26, height: 26)
                                .overlay(
                                    RoundedRectangle(cornerRadius: AppRadius.sm)
                                        .strokeBorder(Color.appControlBorder, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Copy \(hex)")
                        .accessibilityLabel("Copy colour \(hex)")
                    }
                    Spacer(minLength: 0)
                    paletteMenu(board.palette)
                }
                Text(palette.joined(separator: "  "))
                    .font(.appFootnote)
                    .foregroundStyle(Color.appMuted)
                    .textSelection(.enabled)
                Button {
                    vm.findImagesMatchingPalette(Array(palette.prefix(5)), title: "Matching \(fileURL.lastPathComponent) palette")
                } label: {
                    Label("Find Images Matching Palette", systemImage: "sparkle.magnifyingglass")
                        .font(.appCaption)
                }
                .buttonStyle(AppLabeledButtonStyle(height: 24, horizontalPadding: AppSpacing.md))
                .help("Rank images \(vm.visualScopeDescription) by how well they match this board's palette")
            }
        }

        if !compact, !board.assets.isEmpty {
            ArtOfficialCard(title: "Images (\(board.assets.count))") {
                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    ForEach(board.assets.prefix(200)) { asset in
                        HStack(spacing: AppSpacing.md) {
                            EmbeddedImageThumbnail(
                                image: asset.image,
                                cacheKey: "\(fileURL.path)#asset:\(asset.id)",
                                size: CGSize(width: 44, height: 44)
                            )
                            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                                Text(asset.name.isEmpty ? "Untitled image" : asset.name)
                                    .font(.appCaption)
                                    .foregroundStyle(Color.appPrimaryText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if asset.kind == .logo || board.logo?.assetId == asset.id {
                                    Text("Logo")
                                        .font(.appFootnote)
                                        .foregroundStyle(Color.appMuted)
                                } else if board.background?.assetId == asset.id {
                                    Text("Background")
                                        .font(.appFootnote)
                                        .foregroundStyle(Color.appMuted)
                                } else if !asset.image.isResolvable {
                                    Text("Not embedded")
                                        .font(.appFootnote)
                                        .foregroundStyle(Color.appMuted)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    if board.assets.count > 200 {
                        Text("+\(board.assets.count - 200) more")
                            .font(.appFootnote)
                            .foregroundStyle(Color.appMuted)
                    }
                }
            }
        }
    }

    private func layoutLabel(_ board: Moodboard) -> String {
        let mode = board.layoutMode.rawValue.capitalized
        if board.aspectRatio != "auto" { return "\(mode) · \(board.aspectRatio)" }
        return mode
    }

    private func tileLabel(_ board: Moodboard) -> String {
        let images = board.imageTileCount
        let others = board.tiles.count - images
        return others > 0 ? "\(board.tiles.count) (\(images) images)" : "\(board.tiles.count)"
    }

    private func moodActionsMenu(_ board: Moodboard) -> some View {
        Menu {
            Button("Open in Mood") { vm.openInOwnerApp(item) }
            Divider()
            Button("Extract Images…") { vm.extractEmbeddedImages(from: item) }
            Button("Export Board as PNG…") { vm.exportRenderedImage(of: item) }
            Menu("Copy Palette") {
                ForEach(PaletteCopyFormat.allCases) { format in
                    Button(format.title) { vm.copyPalette(board.palette, format: format) }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.appCallout)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Mood Board Actions")
        .accessibilityLabel("Mood Board Actions")
    }

    private func paletteMenu(_ palette: [String]) -> some View {
        Menu {
            ForEach(PaletteCopyFormat.allCases) { format in
                Button(format.title) { vm.copyPalette(palette, format: format) }
            }
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.appCaption)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Copy Palette")
        .accessibilityLabel("Copy Palette")
    }

    // MARK: - Story

    @ViewBuilder
    private func storySections(_ story: StoryDocument) -> some View {
        let project = currentProject(in: story)

        ArtOfficialCard(title: nil) {
            HStack(alignment: .top, spacing: AppSpacing.sm) {
                Image(systemName: "film.stack")
                    .font(.appCallout)
                    .foregroundStyle(Color.badgeStoryText)
                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                    Text(project?.title ?? "Untitled")
                        .font(.appHeadline)
                        .foregroundStyle(Color.appPrimaryText)
                        .textSelection(.enabled)
                    if let project {
                        Text([project.code, project.status].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.appCaption)
                            .foregroundStyle(Color.appMuted)
                    }
                }
                Spacer(minLength: 0)
                storyActionsMenu(projectID: project?.id)
            }

            if story.projects.count > 1 {
                Picker("Project", selection: projectBinding(story)) {
                    ForEach(story.projects) { p in
                        Text(p.isUnassigned ? StoryReader.unassignedName : p.title).tag(Optional(p.id))
                    }
                }
                .pickerStyle(.menu)
                .font(.appCaption)
            }

            if let logline = project?.logline, !logline.isEmpty {
                Text(logline)
                    .font(.appBody)
                    .foregroundStyle(Color.appPrimaryText.opacity(0.9))
                    .textSelection(.enabled)
            }
            ownerAppButton(kind: .story)
        }

        if let project {
            ArtOfficialCard(title: "Project") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: AppSpacing.md) {
                    statCell("Scenes", "\(project.scenes.filter { !$0.isUnassigned }.count)")
                    statCell("Shots", "\(project.shotCount)")
                    statCell("Scripts", "\(project.scripts.count)")
                    statCell("Runtime", project.estimatedDurationSec > 0
                        ? ArtOfficialTextExport.formatDuration(project.estimatedDurationSec) : "—")
                }
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    infoRow("Aspect", project.aspectRatio)
                    if let director = project.director, !director.isEmpty { infoRow("Director", director) }
                    if let producer = project.producer, !producer.isEmpty { infoRow("Producer", producer) }
                    if let dates = dateRange(project) { infoRow("Dates", dates) }
                }
                .padding(.top, AppSpacing.xs)
            }

            if !compact {
                outlineCard(project)
                if !project.scripts.isEmpty {
                    ArtOfficialCard(title: "Scripts (\(project.scripts.count))") {
                        VStack(alignment: .leading, spacing: AppSpacing.sm) {
                            ForEach(Array(project.scripts.enumerated()), id: \.offset) { _, script in
                                HStack(spacing: AppSpacing.sm) {
                                    Image(systemName: "doc.plaintext")
                                        .font(.appCaption)
                                        .foregroundStyle(Color.appMuted)
                                    VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                                        Text(script.name.isEmpty ? script.filename : script.name)
                                            .font(.appCaption)
                                            .foregroundStyle(Color.appPrimaryText)
                                            .lineLimit(1)
                                        Text(scriptDetail(script))
                                            .font(.appFootnote)
                                            .foregroundStyle(Color.appMuted)
                                    }
                                    Spacer(minLength: 0)
                                    Button {
                                        ClipboardService.copyString(script.content)
                                        vm.showToast("Script copied", type: .success)
                                    } label: {
                                        Image(systemName: "doc.on.doc")
                                            .font(.appCaption)
                                    }
                                    .buttonStyle(AppIconButtonStyle(width: 22, height: 22, cornerRadius: AppRadius.sm, showsRestingChrome: false))
                                    .help("Copy Script Text")
                                    .accessibilityLabel("Copy Script Text")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func outlineCard(_ project: StoryProject) -> some View {
        let scenes = project.scenes.filter { !$0.shots.isEmpty || !$0.isUnassigned }
        if !scenes.isEmpty {
            ArtOfficialCard(title: "Outline") {
                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    ForEach(Array(scenes.enumerated()), id: \.offset) { offset, scene in
                        VStack(alignment: .leading, spacing: AppSpacing.sm) {
                            HStack(spacing: AppSpacing.sm) {
                                Text(scene.isUnassigned ? StoryReader.unassignedName
                                     : "\(scene.number > 0 ? scene.number : offset + 1). \(scene.name)")
                                    .font(.appCalloutEmphasis)
                                    .foregroundStyle(Color.appPrimaryText)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Text("\(scene.shots.count) shot\(scene.shots.count == 1 ? "" : "s")")
                                    .font(.appFootnote)
                                    .foregroundStyle(Color.appMuted)
                            }
                            if !scene.isUnassigned, !scene.location.isEmpty {
                                Text(scene.slugline)
                                    .font(.appFootnote)
                                    .foregroundStyle(Color.badgeStoryText)
                            }
                            ForEach(Array(scene.shots.prefix(100).enumerated()), id: \.offset) { shotOffset, shot in
                                shotRow(shot, number: shotOffset + 1)
                            }
                            if scene.shots.count > 100 {
                                Text("+\(scene.shots.count - 100) more shots")
                                    .font(.appFootnote)
                                    .foregroundStyle(Color.appMuted)
                            }
                        }
                        if offset < scenes.count - 1 {
                            Divider().background(Color.appBorder.opacity(0.5))
                        }
                    }
                }
            }
        }
    }

    private func shotRow(_ shot: StoryShot, number: Int) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            EmbeddedImageThumbnail(
                image: shot.thumb,
                cacheKey: "\(fileURL.path)#shot:\(shot.id)",
                size: CGSize(width: 64, height: 36)
            )
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                HStack(spacing: AppSpacing.xs) {
                    Text("\(number).")
                        .font(.appCaptionEmphasis)
                        .foregroundStyle(Color.badgeStoryText)
                    Text(shot.name.isEmpty ? "Untitled shot" : shot.name)
                        .font(.appCaption)
                        .foregroundStyle(Color.appPrimaryText)
                        .lineLimit(1)
                    let types = shot.types.filter { !$0.isEmpty }
                    if !types.isEmpty {
                        Text(types.joined(separator: ", "))
                            .font(.appMicro)
                            .foregroundStyle(Color.appMuted)
                            .padding(.horizontal, AppSpacing.xs)
                            .padding(.vertical, AppSpacing.xxs)
                            .background(Capsule().fill(Color.appElevatedSurface))
                    }
                }
                if !shot.description.isEmpty {
                    Text(shot.description)
                        .font(.appFootnote)
                        .foregroundStyle(Color.appMuted)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func storyActionsMenu(projectID: String?) -> some View {
        Menu {
            Button("Open in Story") { vm.openInOwnerApp(item) }
            Divider()
            Button("Extract Shot Thumbnails…") { vm.extractEmbeddedImages(from: item, projectID: projectID) }
            Button("Export Contact Sheet…") { vm.exportRenderedImage(of: item, projectID: projectID) }
            Menu("Copy Shot List") {
                ForEach(ShotListFormat.allCases) { format in
                    Button(format.title) { vm.copyShotList(of: item, format: format, projectID: projectID) }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.appCallout)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Story Project Actions")
        .accessibilityLabel("Story Project Actions")
    }

    private func currentProject(in story: StoryDocument) -> StoryProject? {
        if let selectedProjectID, let project = story.projects.first(where: { $0.id == selectedProjectID }) {
            return project
        }
        return story.defaultProject
    }

    private func projectBinding(_ story: StoryDocument) -> Binding<String?> {
        Binding(
            get: { currentProject(in: story)?.id },
            set: { selectedProjectID = $0 }
        )
    }

    private func dateRange(_ project: StoryProject) -> String? {
        switch (project.dateStart?.isEmpty == false ? project.dateStart : nil,
                project.dateEnd?.isEmpty == false ? project.dateEnd : nil) {
        case let (start?, end?): return "\(start) – \(end)"
        case let (start?, nil): return "From \(start)"
        case let (nil, end?): return "Until \(end)"
        default: return nil
        }
    }

    private func scriptDetail(_ script: StoryScript) -> String {
        let lines = script.content.split(whereSeparator: \.isNewline).count
        let file = script.filename.isEmpty ? nil : script.filename
        return [file, "\(lines) line\(lines == 1 ? "" : "s")"].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: - Shared pieces

    private func ownerAppButton(kind: ArtOfficialDocument.Kind) -> some View {
        Button {
            vm.openInOwnerApp(item)
        } label: {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: "arrow.up.forward.app")
                    .font(.appCallout)
                Text("Open in \(kind.ownerAppName)")
                    .font(.appIcon(12, weight: .medium))
            }
            .foregroundStyle(Color.appAccent)
            .padding(.horizontal, AppSpacing.lg)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(Color.appAccent.opacity(0.12))
            .cornerRadius(AppRadius.md)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .strokeBorder(Color.appAccent.opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(AppAdaptiveButtonStyle())
        .padding(.top, AppSpacing.xs)
    }

    private func statCell(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
            Text(title)
                .font(.appFootnote)
                .foregroundStyle(Color.appMuted)
            Text(value)
                .font(.appIcon(13, weight: .medium))
                .foregroundStyle(Color.appPrimaryText)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appSurface)
        .cornerRadius(AppRadius.md)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            Text(label)
                .font(.appCaption)
                .foregroundStyle(Color.appMuted)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.appCaption)
                .foregroundStyle(Color.appPrimaryText)
                .textSelection(.enabled)
        }
    }
}

/// The details panel's card look (title above an inset surface).
struct ArtOfficialCard<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            if let title {
                Text(title)
                    .font(.appIcon(11, weight: .medium))
                    .foregroundStyle(Color.appMuted)
            }
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                content
            }
            .padding(AppSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.appSurface.opacity(0.6))
            .cornerRadius(AppRadius.lg)
        }
    }
}

// MARK: - Embedded image thumbnails

/// Decodes an `EmbeddedImage` off the main actor into a small cached thumbnail.
struct EmbeddedImageThumbnail: View {
    let image: EmbeddedImage?
    let cacheKey: String
    let size: CGSize

    @State private var decoded: NSImage?

    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 600
        return cache
    }()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppRadius.xs)
                .fill(Color.appElevatedSurface)
            if let decoded {
                Image(nsImage: decoded)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: image?.isResolvable == false ? "icloud.slash" : "photo")
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.xs))
        .task(id: cacheKey) {
            await load()
        }
    }

    private func load() async {
        let key = "\(cacheKey)|\(Int(max(size.width, size.height)))" as NSString
        if let cached = Self.cache.object(forKey: key) {
            decoded = cached
            return
        }
        decoded = nil
        guard let image, image.isResolvable else { return }
        let pixels = Int(max(size.width, size.height) * 2)
        let cg = await Task.detached(priority: .utility) { image.cgImage(maxPixelSize: pixels) }.value
        guard !Task.isCancelled, let cg else { return }
        let ns = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        Self.cache.setObject(ns, forKey: key)
        decoded = ns
    }
}

// MARK: - Send progress

/// Floating capsule shown while Send to Mood / Send to Story builds its file.
struct ArtOfficialSendProgressView: View {
    let progress: ArtOfficialSendProgress

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                .progressViewStyle(.linear)
                .frame(width: 140)
                .tint(Color.appAccent)
            Text("\(progress.title)… \(progress.done) of \(progress.total)")
                .font(.appCaption)
                .foregroundStyle(Color.appPrimaryText)
                .monospacedDigit()
        }
        .padding(.horizontal, AppSpacing.xl)
        .padding(.vertical, 10)
        .background(Color.appSurface)
        .cornerRadius(AppRadius.md)
        .shadow(color: Color.appShadowColor.opacity(0.9), radius: 8, y: 4)
        .padding(.bottom, AppSpacing.xxl)
        .accessibilityElement(children: .combine)
    }
}
