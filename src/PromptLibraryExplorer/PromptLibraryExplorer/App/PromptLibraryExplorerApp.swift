import AppKit
import SwiftUI

@main
struct PromptLibraryExplorerApp: App {
    @State private var explorerVM = ExplorerViewModel()

    private let undoSelector = NSSelectorFromString("undo:")
    private let redoSelector = NSSelectorFromString("redo:")

    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        WindowGroup {
            MainContentView()
                .environment(explorerVM)
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(explorerVM.appearanceMode.colorScheme)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder...") {
                    Task { await explorerVM.openFolder() }
                }
                .keyboardShortcut("o", modifiers: .command)

                Menu("Open Recent") {
                    if explorerVM.recentFolders.isEmpty {
                        Text("No Recent Folders")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(explorerVM.recentFolders) { item in
                            Button(item.name) {
                                Task { await explorerVM.openRecentFolder(item) }
                            }
                        }
                    }

                    Divider()

                    Button("Clear Recents") {
                        explorerVM.clearRecentFolders()
                    }
                    .disabled(explorerVM.recentFolders.isEmpty)
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    explorerVM.settingsOpen = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .undoRedo) {
                Button(undoCommandTitle) {
                    performUndo()
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!canUndo)

                Button(redoCommandTitle) {
                    performRedo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!canRedo)
            }
            CommandGroup(replacing: .help) {
                Button("PromptLibrary Explorer Help") {
                    explorerVM.helpOpen = true
                }

                Divider()

                Button("Developer Website") {
                    explorerVM.openDeveloperWebsite()
                }
            }
            CommandGroup(after: .toolbar) {
                Toggle("Status Bar", isOn: Binding(
                    get: { explorerVM.showStatusBar },
                    set: { newValue in
                        explorerVM.showStatusBar = newValue
                        explorerVM.persistStatusBarVisibility()
                    }
                ))

                Divider()

                Button("Refresh") {
                    Task { await explorerVM.refreshFolder() }
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Compare Selected .aoe Files") {
                    Task { await explorerVM.openComparison() }
                }
                .disabled(explorerVM.selectedAoeItems.count < 2 || explorerVM.isLoadingComparison)

                Divider()

                Button("Folder Statistics") {
                    explorerVM.statisticsOpen = true
                }
                .disabled(explorerVM.selectedFolderPath == nil)

                Button("New Smart Folder...") {
                    explorerVM.editingSmartFolder = nil
                    explorerVM.showSmartFolderEditor = true
                }
            }
        }
    }

    private var currentUndoManager: UndoManager? {
        NSApp.keyWindow?.undoManager ?? NSApp.mainWindow?.undoManager
    }

    private var canNativeUndo: Bool {
        currentUndoManager?.canUndo == true
    }

    private var canNativeRedo: Bool {
        currentUndoManager?.canRedo == true
    }

    private var nativeUndoActionName: String? {
        guard canNativeUndo else { return nil }
        let name = currentUndoManager?.undoActionName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? nil : name
    }

    private var nativeRedoActionName: String? {
        guard canNativeRedo else { return nil }
        let name = currentUndoManager?.redoActionName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? nil : name
    }

    private var canUndo: Bool {
        canNativeUndo || explorerVM.canUndoFolderAction
    }

    private var canRedo: Bool {
        canNativeRedo || explorerVM.canRedoFolderAction
    }

    private var undoCommandTitle: String {
        if let nativeUndoActionName {
            return "Undo \(nativeUndoActionName)"
        }
        if explorerVM.canUndoFolderAction {
            return explorerVM.undoMenuTitle
        }
        return "Undo"
    }

    private var redoCommandTitle: String {
        if let nativeRedoActionName {
            return "Redo \(nativeRedoActionName)"
        }
        if explorerVM.canRedoFolderAction {
            return explorerVM.redoMenuTitle
        }
        return "Redo"
    }

    private func performUndo() {
        if canNativeUndo {
            NSApp.sendAction(undoSelector, to: nil, from: nil)
            return
        }

        guard explorerVM.canUndoFolderAction else { return }
        Task { await explorerVM.undoLastFolderAction() }
    }

    private func performRedo() {
        if canNativeRedo {
            NSApp.sendAction(redoSelector, to: nil, from: nil)
            return
        }

        guard explorerVM.canRedoFolderAction else { return }
        Task { await explorerVM.redoLastFolderAction() }
    }
}
