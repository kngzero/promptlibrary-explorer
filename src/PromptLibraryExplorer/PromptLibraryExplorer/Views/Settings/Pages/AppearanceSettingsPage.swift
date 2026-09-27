import SwiftUI

struct AppearanceSettingsPage: View {
    @Environment(ExplorerViewModel.self) private var vm

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
    }
}
