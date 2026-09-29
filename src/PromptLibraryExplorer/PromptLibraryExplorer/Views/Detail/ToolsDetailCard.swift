import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The details panel's Tools section: a grid of the tools that fit the file
/// shown (crop and adjust for images, trim for video and audio, metadata for
/// files that carry it…), always ending with Open With. (More Like This and
/// palette search are in Dominant Colours.)
struct ToolsDetailCard: View {
    @Environment(ExplorerViewModel.self) private var vm
    let entry: PromptEntry
    let path: String

    private var edits: EditController { .shared }
    private var media: MediaController { .shared }
    private var name: String { (path as NSString).lastPathComponent }
    private var url: URL { URL(fileURLWithPath: path) }
    private var item: FileEntry {
        vm.listingSourceContents.first { $0.path == path } ?? FileEntry(url: url, isDirectory: false)
    }

    struct Tool: Identifiable {
        let id: String
        let title: String
        let systemImage: String
        var help: String?
        var isEnabled = true
        /// Opens a menu (shows a chevron).
        var opensMenu = false
        let action: () -> Void
    }

    var body: some View {
        DetailCard(title: "Tools") {
            if let recipe = edits.recipe(for: path) {
                HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
                    EditedBadge()
                    Text(recipe.summary)
                        .font(.appCaption)
                        .foregroundStyle(Color.appMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: AppSpacing.md)], spacing: AppSpacing.md) {
                ForEach(tools) { tool in
                    Button(action: tool.action) {
                        ToolTileLabel(title: tool.title, systemImage: tool.systemImage, opensMenu: tool.opensMenu)
                    }
                    .buttonStyle(ToolTileButtonStyle())
                    .disabled(!tool.isEnabled)
                    .help(tool.help ?? tool.title)
                }
            }
        }
    }

    private var tools: [Tool] {
        var tools: [Tool] = []
        if EditEligibility.isEditable(name) {
            tools.append(Tool(id: "edit", title: "Crop & Adjust", systemImage: "crop.rotate",
                              help: "Crop, straighten, rotate, flip and adjust without changing the file",
                              isEnabled: !vm.isEditorPageActive) { vm.openEditor(for: item) })
            if edits.isEdited(path) {
                tools.append(Tool(id: "saveCopy", title: "Save Edited Copy", systemImage: "doc.badge.plus",
                                  help: "Save the edited image as a new file next to the original") { vm.saveEditedCopy(of: item) })
                tools.append(Tool(id: "revert", title: "Revert to Original", systemImage: "arrow.counterclockwise",
                                  help: "Revert to Original (undoable)") { vm.revertToOriginal(paths: [path]) })
            }
        }
        if FileHelpers.isVideoFile(name) {
            tools.append(Tool(id: "trimVideo", title: "Trim Video", systemImage: "scissors",
                              help: "Trim & Export Clip… as MP4 or an animated GIF",
                              isEnabled: !media.isExporting) { vm.openTrim(for: item) })
            tools.append(Tool(id: "frame", title: "Save Middle Frame", systemImage: "photo.on.rectangle",
                              isEnabled: !media.isSavingFrame) { vm.saveMiddleFrames(for: item) })
        } else if FileHelpers.isAudioFile(name) {
            tools.append(Tool(id: "trimAudio", title: "Trim Audio", systemImage: "scissors",
                              help: "Trim & Export Audio… as M4A",
                              isEnabled: !media.isExporting) { vm.openTrim(for: item) })
        }
        if vm.isEmbeddableMetadataFile(path) {
            let hasMetadata = !entry.prompt.isEmpty || !entry.embeddedMetadata.isEmpty || entry.generationInfo.model != "N/A"
            let audio = vm.isEmbeddableAudioFile(path)
            let title = audio ? (hasMetadata ? "Edit Audio Tags" : "Add Audio Tags") : (hasMetadata ? "Edit Metadata" : "Add Metadata")
            tools.append(Tool(id: "metadata", title: title, systemImage: hasMetadata ? "pencil.line" : "plus.square",
                              help: "Written into the file") { vm.openMetadataEditor(for: path) })
        }
        if FileHelpers.isImageFile(name) {
            tools.append(Tool(id: "export", title: "Export…", systemImage: "square.and.arrow.up.on.square",
                              help: "Resize and convert with an export preset", isEnabled: vm.canExport) { vm.openExportSheet() })
        }
        tools.append(Tool(id: "openWith", title: "Open With", systemImage: "arrow.up.forward.app",
                          help: "Choose an app to open this file", opensMenu: true) { OpenWithMenu.show(for: url) })
        return tools
    }
}

/// Icon over a one- or two-line title, centred.
private struct ToolTileLabel: View {
    let title: String
    let systemImage: String
    var opensMenu = false

    var body: some View {
        VStack(spacing: AppSpacing.sm) {
            Image(systemName: systemImage)
                .font(.appIcon(18, weight: .regular))
                .frame(height: 22)
            HStack(spacing: AppSpacing.xxs) {
                Text(title)
                    .font(.appCaption)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if opensMenu {
                    Image(systemName: "chevron.right")
                        .font(.appIcon(8, weight: .bold))
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.horizontal, AppSpacing.xs)
        .frame(maxWidth: .infinity)
    }
}

/// A square-ish tool tile on the raised surface; hover lifts, press tints.
struct ToolTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ToolTileSurface(label: configuration.label, isPressed: configuration.isPressed)
    }
}

private struct ToolTileSurface<Label: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false
    let label: Label
    let isPressed: Bool

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous) }

    var body: some View {
        ZStack {
            shape.fill(Color.appElevatedSurface)
            shape.fill(isPressed ? Color.appSelected : isHovering ? Color.appHover : Color.clear)
            shape.strokeBorder(isPressed ? Color.appAccent.opacity(0.55) : isHovering ? Color.appControlBorder : Color.appBorder, lineWidth: 1)
            label
                .foregroundStyle(
                    !isEnabled ? Color.appMuted.opacity(0.4)
                        : isPressed ? Color.appAccentHover
                        : isHovering ? Color.appPrimaryText : Color.appPrimaryText.opacity(0.85)
                )
        }
        .frame(height: 72)
        .contentShape(shape)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering && isEnabled }
        }
    }
}

/// The Open With menu (apps that open the file, the default first, then Other…),
/// popped up at the pointer.
@MainActor
enum OpenWithMenu {
    static func show(for url: URL) {
        let target = Target(fileURL: url)
        let menu = NSMenu()
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)?.standardizedFileURL
        var apps = FileSystemService.applicationsForFile(url: url).map(\.standardizedFileURL)
        if let defaultApp, let index = apps.firstIndex(of: defaultApp) {
            apps.insert(apps.remove(at: index), at: 0)
        }
        var seen = Set<String>()
        for app in apps where seen.insert(app.path).inserted {
            var title = FileManager.default.displayName(atPath: app.path)
            if title.hasSuffix(".app") { title = String(title.dropLast(4)) }
            if app == defaultApp { title += " (default)" }
            let menuItem = NSMenuItem(title: title, action: #selector(Target.open(_:)), keyEquivalent: "")
            menuItem.target = target
            menuItem.representedObject = app
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            menuItem.image = icon
            menu.addItem(menuItem)
            if app == defaultApp, apps.count > 1 { menu.addItem(.separator()) }
        }
        if apps.isEmpty {
            let none = NSMenuItem(title: "No Apps Found", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        menu.addItem(.separator())
        let other = NSMenuItem(title: "Other…", action: #selector(Target.chooseOther(_:)), keyEquivalent: "")
        other.target = target
        menu.addItem(other)
        // popUp blocks until the menu closes; the target lives until then.
        withExtendedLifetime(target) {
            _ = menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    private final class Target: NSObject {
        let fileURL: URL
        init(fileURL: URL) { self.fileURL = fileURL }

        @objc func open(_ sender: NSMenuItem) {
            guard let app = sender.representedObject as? URL else { return }
            FileSystemService.openFile(url: fileURL, withApplication: app)
        }

        @objc func chooseOther(_ sender: NSMenuItem) {
            let panel = NSOpenPanel()
            panel.title = "Open With"
            panel.prompt = "Open"
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.allowedContentTypes = [.application]
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let app = panel.url else { return }
            FileSystemService.openFile(url: fileURL, withApplication: app)
        }
    }
}
