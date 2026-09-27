import SwiftUI

struct HelpView: View {
    @Environment(ExplorerViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sectionCard(
                        title: "File Types",
                        description: "Understand the two primary snapshot formats supported by the app.",
                        icon: "doc.text.magnifyingglass",
                        accent: Color.appAccent
                    ) {
                        VStack(spacing: 14) {
                            ForEach(HelpContent.fileTypes) { fileType in
                                fileTypeCard(fileType)
                            }
                        }
                    }

                    sectionCard(
                        title: "Keyboard Shortcuts",
                        description: "Shortcuts grouped by the part of the app where they apply.",
                        icon: "command",
                        accent: Color.appAccentHover
                    ) {
                        VStack(spacing: 14) {
                            ForEach(HelpContent.shortcutGroups) { group in
                                shortcutGroupCard(group)
                            }
                        }
                    }

                    sectionCard(
                        title: "Developer",
                        description: "Art Official builds PromptLibrary Explorer and the connected creative workflow tools around it.",
                        icon: "globe",
                        accent: Color.segmentPlaceText
                    ) {
                        developerCard
                    }
                }
                .padding(20)
            }

            footer
        }
        .frame(width: 720, height: 640)
        .background(Color.appBackground)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .fill(Color.appElevatedSurface)
                Image(systemName: "questionmark.circle.fill")
                    .font(.appLargeTitle)
                    .foregroundStyle(Color.appAccent)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text("Help")
                    .font(.appIcon(24, weight: .bold))
                    .foregroundStyle(Color.appPrimaryText)

                Text("Reference for file types, keyboard shortcuts, and developer resources.")
                    .font(.appIcon(14))
                    .foregroundStyle(Color.appMuted)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(Color.appBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.appBorder)
                .frame(height: 1)
        }
    }

    private func sectionCard(
        title: String,
        description: String,
        icon: String,
        accent: Color,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xl) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: AppRadius.lg)
                        .fill(accent.opacity(0.14))
                    Image(systemName: icon)
                        .font(.appLargeTitle)
                        .foregroundStyle(accent)
                }
                .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    Text(title)
                        .font(.appIcon(18, weight: .semibold))
                        .foregroundStyle(Color.appPrimaryText)

                    Text(description)
                        .font(.appIcon(14))
                        .foregroundStyle(Color.appMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xxl)
                .fill(Color.appSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xxl)
                .strokeBorder(Color.appBorder, lineWidth: 1)
        )
    }

    private func fileTypeCard(_ fileType: HelpFileTypeDescription) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(fileType.extensionLabel)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.appAccent)
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.vertical, AppSpacing.xs)
                    .background(
                        Capsule()
                            .fill(Color.appAccent.opacity(0.12))
                    )

                Text(fileType.title)
                    .font(.appIcon(17, weight: .semibold))
                    .foregroundStyle(Color.appPrimaryText)
            }

            Text(fileType.description)
                .font(.appIcon(14))
                .foregroundStyle(Color.appMuted)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: AppSpacing.md) {
                ForEach(fileType.highlights, id: \.self) { highlight in
                    HStack(alignment: .top, spacing: AppSpacing.md) {
                        Image(systemName: "circle.fill")
                            .font(.appIcon(5))
                            .foregroundStyle(Color.appAccent)
                            .padding(.top, AppSpacing.sm)

                        Text(highlight)
                            .font(.appBody)
                            .foregroundStyle(Color.appPrimaryText.opacity(0.92))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(AppSpacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .fill(Color.appElevatedSurface.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .strokeBorder(Color.appBorder, lineWidth: 1)
        )
    }

    private func shortcutGroupCard(_ group: HelpShortcutGroup) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(group.title)
                    .font(.appIcon(17, weight: .semibold))
                    .foregroundStyle(Color.appPrimaryText)

                Text(group.description)
                    .font(.appBody)
                    .foregroundStyle(Color.appMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                ForEach(group.items) { item in
                    HStack(alignment: .top, spacing: 14) {
                        HStack(spacing: AppSpacing.sm) {
                            ForEach(item.keys, id: \.self) { key in
                                shortcutKey(key)
                            }
                        }
                        .frame(minWidth: 168, alignment: .leading)

                        Text(item.description)
                            .font(.appBody)
                            .foregroundStyle(Color.appPrimaryText.opacity(0.92))
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(AppSpacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .fill(Color.appElevatedSurface.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .strokeBorder(Color.appBorder, lineWidth: 1)
        )
    }

    private func shortcutKey(_ key: String) -> some View {
        Text(key)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color.appPrimaryText)
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .fill(Color.appBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .strokeBorder(Color.appControlBorder, lineWidth: 1)
            )
    }

    private var developerCard: some View {
        let resource = HelpContent.developerResource

        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Text(resource.title)
                    .font(.appIcon(18, weight: .semibold))
                    .foregroundStyle(Color.appPrimaryText)

                Text(resource.description)
                    .font(.appIcon(14))
                    .foregroundStyle(Color.appMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                vm.openDeveloperWebsite()
            } label: {
                HStack(spacing: AppSpacing.md) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.appHeadline)
                    Text(resource.buttonTitle)
                        .font(.appTitle)
                }
            }
            // White on the pale teal fill was ~2:1; the text-safe teal with the
            // canvas colour as its label stays above 6:1 in both modes.
            .buttonStyle(
                AppPrimaryButtonStyle(
                    tint: .segmentPlaceText,
                    foreground: .appCanvasBackground,
                    horizontalPadding: AppSpacing.xl,
                    verticalPadding: 10,
                    cornerRadius: AppRadius.lg
                )
            )

            Text(resource.urlString)
                .font(.appMono)
                .foregroundStyle(Color.appMuted)
        }
        .padding(AppSpacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .fill(Color.appElevatedSurface.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .strokeBorder(Color.appBorder, lineWidth: 1)
        )
    }

    private var footer: some View {
        HStack {
            Button {
                vm.openDeveloperWebsite()
            } label: {
                Label("Developer Website", systemImage: "link")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.appAccentHover)

            Spacer()

            Button("Close") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, AppSpacing.xl)
        .background(Color.appBackground)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.appBorder)
                .frame(height: 1)
        }
    }
}
