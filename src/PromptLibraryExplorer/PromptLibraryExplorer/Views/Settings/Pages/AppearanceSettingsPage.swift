import SwiftUI

struct AppearanceSettingsPage: View {
    @Environment(ExplorerViewModel.self) private var vm
    @AppStorage(ContentItemContextMenu.compactKey) private var compactContextMenu = true

    var body: some View {
        SettingsCard(title: "Theme", icon: "circle.lefthalf.filled") {
            Picker(
                "Appearance",
                selection: Binding(
                    get: { vm.appearanceMode },
                    set: { newValue in
                        vm.appearanceMode = newValue
                        vm.persistAppearanceMode()
                        newValue.applyToApp()
                    }
                )
            ) {
                ForEach(AppAppearanceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            SettingsFootnote("System follows your Mac's appearance setting and switches automatically. Light mode mirrors the dark neutrals into lighter counterparts while keeping the app accent intact.")
        }

        SettingsCard(title: "Grid", icon: "square.grid.2x2") {
            SettingsToggleRow(
                title: "Show a dominant-colour strip on grid tiles",
                detail: "A thin bar along the bottom of each thumbnail with the colours the visual index found, each as wide as its share of the image. Files not indexed yet have no strip.",
                isOn: Binding(
                    get: { vm.showTileColorStrip },
                    set: { vm.showTileColorStrip = $0 }
                )
            )

            SettingsToggleRow(
                title: "Scrub videos by hovering over their tiles",
                detail: "Move the pointer across a video's thumbnail (grid or list) to preview it; a thin line shows the position. Leaving the tile shows the poster frame again.",
                isOn: Binding(
                    get: { MediaController.shared.hoverScrubEnabled },
                    set: { MediaController.shared.hoverScrubEnabled = $0 }
                )
            )
        }

        SettingsCard(title: "Right-Click Menu", icon: "contextualmenu.and.cursorarrow") {
            SettingsToggleRow(
                title: "Leave out what the details panel has",
                detail: "For one file, the menu skips Open In, Edit Image, trim and frame tools, More Like This, palette search, Copy Prompt, Copy As, Flag, Rating, Label, Pin, Tags and the prompt tools: they're in the details panel (Tools, Prompt, Prompt Tools, Dominant Colours, Rating & Tags). With several files selected the menu keeps everything.",
                isOn: $compactContextMenu
            )
        }

        // Tips and the welcome tour (Views/Onboarding).
        OnboardingTipsSettingsCard()
    }
}
