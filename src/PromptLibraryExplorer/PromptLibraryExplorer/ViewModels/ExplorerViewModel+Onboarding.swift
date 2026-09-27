import AppKit
import Foundation

// MARK: - Onboarding glue: Help, the welcome tour, tips, "Show Me" commands

extension ExplorerViewModel {
    // MARK: Help

    /// Opens Help, optionally scrolled to one entry or section.
    func openHelp(focus: HelpFocus? = nil) {
        OnboardingController.shared.helpFocus = focus
        if lightboxOpen { lightboxOpen = false }
        helpOpen = true
    }

    /// Help ▸ Welcome Tour…
    func presentWelcomeTour() {
        guard !isAnyModalOpen else { return }
        OnboardingController.shared.presentTour()
    }

    /// Help ▸ Reset Tips.
    func resetTips() {
        OnboardingTipsController.shared.reset()
        showToast("Tips will show again as you use the app", type: .info)
    }

    // MARK: Commands

    /// Whether `command` can run right now (a Show Me button is disabled otherwise).
    func canPerform(_ command: HelpCommand) -> Bool {
        let hasLibrary = explorerRootPath != nil
        switch command {
        case .openFolder, .welcomeTour, .keyboardShortcuts, .snippets, .promptBuilder, .watchedFolders:
            return true
        case .appearanceSettings, .exportSettings, .dataSettings, .integrationSettings, .searchIndexSettings,
             .generatorSettings, .organizeSettings, .storageSettings, .fileOperationsSettings:
            return true
        case .togglePreviewPane, .focusSearch, .findInLibrary, .commandPalette, .similarImages, .similarPrompts,
             .promptStatistics, .reindexLibrary, .newSmartFolder, .writeXMPSidecars, .cullingMode:
            return hasLibrary
        case .compareImages: return canCompareImages
        case .slideshow: return canStartSlideshow
        case .batchRename: return !batchRenameTargets.isEmpty
        case .folderStatistics: return selectedFolderPath != nil
        case .moreLikeThis: return canShowMoreLikeThis
        case .applySuggestedTags: return canApplySuggestedTags
        case .stackVariants: return stackScope != nil
        case .showInbox: return hasLibrary && IngestController.shared.hasSources
        case .sendToMood: return canSendToArtOfficial
        case .export, .exportForSharing, .contactSheet: return canExport
        case .trimClip: return canTrimVideo
        }
    }

    /// Why a Show Me button is disabled.
    func unavailableHint(for command: HelpCommand) -> String {
        guard explorerRootPath != nil else { return "Open a library folder first." }
        switch command {
        case .compareImages: return "Select 2 to 4 images or videos first."
        case .slideshow: return "Open a folder with images first."
        case .batchRename: return "Select the files to rename first."
        case .folderStatistics: return "Select a folder first."
        case .moreLikeThis: return "Select an image or video first."
        case .applySuggestedTags: return "Select analysed images first."
        case .stackVariants: return "Open a folder or collection first."
        case .showInbox: return "Add a watched folder in Settings ▸ Ingest first."
        case .sendToMood: return "Select some images first."
        case .export, .exportForSharing, .contactSheet: return "Select files to export first."
        case .trimClip: return "Select a video first."
        default: return "Not available right now."
        }
    }

    /// Runs `command` as its menu item would.
    func perform(_ command: HelpCommand) {
        if let page = command.settingsPage {
            UserDefaults.standard.set(page.rawValue, forKey: SettingsView.selectedPageKey)
            openSettings()
            return
        }
        switch command {
        case .openFolder:
            Task { await openFolder() }
        case .welcomeTour:
            presentWelcomeTour()
        case .keyboardShortcuts:
            openHelp(focus: .section(.keyboard))
        case .togglePreviewPane:
            togglePreviewPane()
        case .compareImages:
            closeLightboxForCommand()
            compareImagesCommand()
        case .slideshow:
            closeLightboxForCommand()
            startSlideshow()
        case .batchRename:
            batchRenameOpen = true
        case .folderStatistics:
            statisticsOpen = true
        case .cullingMode:
            cullingModeEnabled = true
            showToast("Culling Mode is on: P, X, U, 0–5 and 6–9 work in the grid and the lightbox", type: .info)
        case .focusSearch:
            closeLightboxForCommand()
            Task { @MainActor in NotificationCenter.default.post(name: .focusSearchField, object: nil) }
        case .findInLibrary:
            librarySearchOpen = true
        case .commandPalette:
            closeLightboxForCommand()
            if !commandPaletteOpen {
                Task { @MainActor in NotificationCenter.default.post(name: .toggleCommandPalette, object: nil) }
            }
        case .similarImages:
            closeLightboxForCommand()
            showSimilarImagesPage()
        case .moreLikeThis:
            showMoreLikeThisForTarget()
        case .similarPrompts:
            duplicatesOpen = true
        case .snippets:
            snippetsOpen = true
        case .promptBuilder:
            openPromptBuilderForTarget()
        case .promptStatistics:
            openPromptStatistics()
        case .applySuggestedTags:
            closeLightboxForCommand()
            openApplySuggestedTags()
        case .reindexLibrary:
            reindexLibrary()
        case .newSmartFolder:
            editingSmartFolder = nil
            showSmartFolderEditor = true
        case .stackVariants:
            closeLightboxForCommand()
            if !isStackingEnabled { toggleStackingForCurrentListing() }
        case .showInbox:
            closeLightboxForCommand()
            openInbox()
        case .watchedFolders:
            openIngestSettings()
        case .sendToMood:
            sendToArtOfficial(.mood)
        case .export:
            openExportSheet()
        case .exportForSharing:
            openExportForSharing()
        case .contactSheet:
            openContactSheet()
        case .trimClip:
            openTrimForTarget()
        case .writeXMPSidecars:
            writeXMPSidecarsNow()
        case .appearanceSettings, .exportSettings, .dataSettings, .integrationSettings, .searchIndexSettings,
             .generatorSettings, .organizeSettings, .storageSettings, .fileOperationsSettings:
            break // Handled above.
        }
    }

    /// From a sheet (Help, the tour): close it, then run `command` once it's gone —
    /// a new sheet can't present while another is still dismissing.
    func performAfterDismissingSheets(_ command: HelpCommand) {
        if helpOpen { helpOpen = false }
        if OnboardingController.shared.isTourPresented { OnboardingController.shared.isTourPresented = false }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, self.canPerform(command) else { return }
            self.perform(command)
        }
    }

    private func closeLightboxForCommand() {
        if lightboxOpen { lightboxOpen = false }
    }

    // MARK: Tips

    /// What tips must wait for: anything modal (sheets, alerts, save panels, the
    /// command palette, the tour, another key window, the app in the background)
    /// and typing.
    var tipConditions: TipConditions {
        let modal = isModalBlockingCommands
            || ExportController.shared.isPresenting
            || PromptWorkflowController.shared.isPresenting
            || TagSuggestionController.shared.session != nil
            || IngestController.shared.logSheetOpen
            || commandPaletteOpen
            || OnboardingController.shared.isTourPresented
            || ModalKeyGuard.isAuxiliaryWindowKey
            || !NSApp.isActive
        return TipConditions(isModalOpen: modal, isTyping: ModalKeyGuard.isTextInputFocused)
    }

    /// Whether `tip` still makes sense on screen.
    func isTipRelevant(_ tip: OnboardingTip) -> Bool {
        guard explorerRootPath != nil else { return false }
        let browserHidden = isSimilarImagesPageActive || isComparePageActive
        switch tip {
        case .lightboxOpened:
            return lightboxOpen
        case .promptSelected:
            return !lightboxOpen && !browserHidden && !previewPaneCollapsed
                && !(selectedPromptEntry?.prompt.isEmpty ?? true)
        case .compareSelection:
            return !lightboxOpen && !browserHidden && canCompareImages
        case .largeFolder, .firstCollection, .indexingFinished, .firstExport:
            return !lightboxOpen && !browserHidden
        case .videoSelected:
            return !lightboxOpen && !browserHidden && selectedItems.contains { FileHelpers.isVideoFile($0.name) }
        }
    }

    /// Images in the current listing (for the large-folder tip).
    var listingImageCount: Int {
        processedFolderContents.reduce(0) { $0 + (FileHelpers.isImageFile($1.name) ? 1 : 0) }
    }

    /// Wires the tips controller to this view model (idempotent).
    func configureOnboardingTips() {
        let tips = OnboardingTipsController.shared
        tips.conditionsProvider = { [weak self] in self?.tipConditions ?? TipConditions(isModalOpen: true) }
        tips.relevance = { [weak self] tip in self?.isTipRelevant(tip) ?? false }
    }
}
