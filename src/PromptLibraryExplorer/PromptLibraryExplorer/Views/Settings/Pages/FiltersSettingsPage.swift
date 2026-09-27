import SwiftUI

struct FiltersSettingsPage: View {
    @Environment(ExplorerViewModel.self) private var vm

    /// Mirrors the grouping the header filter menu uses.
    private let typeGroups: [(title: String, types: [FileTypeFilter])] = [
        ("Prompt Files", [.plib, .aoe]),
        ("Art Official Documents", [.moodboard, .story]),
        ("Images", [.png, .jpg, .webp, .gif, .otherImages]),
        ("Media", [.video, .audio]),
        ("Everything Else", [.unsupported])
    ]

    var body: some View {
        SettingsCard(title: "Visible File Types", icon: "line.3.horizontal.decrease.circle") {
            SettingsFootnote("Unchecked types are hidden from every folder. This is the same filter the header menu adjusts.")

            VStack(alignment: .leading, spacing: 14) {
                ForEach(typeGroups, id: \.title) { group in
                    VStack(alignment: .leading, spacing: AppSpacing.sm) {
                        Text(group.title)
                            .font(.appCaptionEmphasis)
                            .tracking(0.4)
                            .foregroundStyle(Color.appMuted)

                        ForEach(group.types, id: \.self) { fileType in
                            SettingsToggleRow(
                                title: fileType.displayName,
                                isOn: visibilityBinding(for: fileType)
                            )
                        }
                    }
                }
            }
            .padding(.top, AppSpacing.xxs)

            HStack(spacing: AppSpacing.lg) {
                Button("Show All Types") {
                    vm.filterConfig.hiddenFileTypes.removeAll()
                    vm.persistFilterConfig()
                }
                .disabled(vm.filterConfig.hiddenFileTypes.isEmpty)

                Button("Reset To Default") {
                    vm.filterConfig.hiddenFileTypes = FilterConfig.defaultHiddenFileTypes
                    vm.persistFilterConfig()
                }
                .disabled(vm.filterConfig.hiddenFileTypes == FilterConfig.defaultHiddenFileTypes)
            }
            .padding(.top, AppSpacing.xs)
        }

        SettingsCard(title: "Minimum Rating", icon: "star.fill") {
            Picker("Minimum Rating", selection: minRatingBinding) {
                Text("Any").tag(0)
                ForEach(1...5, id: \.self) { stars in
                    Text("\(stars)+").tag(stars)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            SettingsFootnote(minRatingFootnote)
        }
    }

    private func visibilityBinding(for fileType: FileTypeFilter) -> Binding<Bool> {
        Binding(
            get: { !vm.filterConfig.hides(fileType) },
            set: { isVisible in
                vm.filterConfig.setHidden(!isVisible, for: fileType)
                vm.persistFilterConfig()
            }
        )
    }

    private var minRatingBinding: Binding<Int> {
        Binding(
            get: { vm.filterConfig.filterMinRating },
            set: { newValue in
                vm.filterConfig.filterMinRating = newValue
                vm.persistFilterConfig()
            }
        )
    }

    private var minRatingFootnote: String {
        let rating = vm.filterConfig.filterMinRating
        guard rating > 0 else {
            return "Files are shown whether or not they are rated."
        }
        return "Only files rated \(rating) star\(rating == 1 ? "" : "s") or higher are shown. Unrated files are hidden."
    }
}
