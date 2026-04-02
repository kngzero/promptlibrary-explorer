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
                        accent: Color.segmentPlace
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
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.appElevatedSurface)
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 4) {
                Text("Help")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Color.appPrimaryText)

                Text("Reference for file types, keyboard shortcuts, and developer resources.")
                    .font(.system(size: 14))
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
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(accent.opacity(0.14))
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(accent)
                }
                .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.appPrimaryText)

                    Text(description)
                        .font(.system(size: 14))
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
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.appSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.appBorder, lineWidth: 1)
        )
    }

    private func fileTypeCard(_ fileType: HelpFileTypeDescription) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(fileType.extensionLabel)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.appAccent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.appAccent.opacity(0.12))
                    )

                Text(fileType.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.appPrimaryText)
            }

            Text(fileType.description)
                .font(.system(size: 14))
                .foregroundStyle(Color.appMuted)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(fileType.highlights, id: \.self) { highlight in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 5))
                            .foregroundStyle(Color.appAccent)
                            .padding(.top, 6)

                        Text(highlight)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.appPrimaryText.opacity(0.92))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.appElevatedSurface.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.appBorder, lineWidth: 1)
        )
    }

    private func shortcutGroupCard(_ group: HelpShortcutGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(group.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.appPrimaryText)

                Text(group.description)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.appMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                ForEach(group.items) { item in
                    HStack(alignment: .top, spacing: 14) {
                        HStack(spacing: 6) {
                            ForEach(item.keys, id: \.self) { key in
                                shortcutKey(key)
                            }
                        }
                        .frame(minWidth: 168, alignment: .leading)

                        Text(item.description)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.appPrimaryText.opacity(0.92))
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.appElevatedSurface.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.appBorder, lineWidth: 1)
        )
    }

    private func shortcutKey(_ key: String) -> some View {
        Text(key)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color.appPrimaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.appBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.appControlBorder, lineWidth: 1)
            )
    }

    private var developerCard: some View {
        let resource = HelpContent.developerResource

        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(resource.title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.appPrimaryText)

                Text(resource.description)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.appMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                vm.openDeveloperWebsite()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 13, weight: .semibold))
                    Text(resource.buttonTitle)
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.segmentPlace)
                )
            }
            .buttonStyle(.plain)

            Text(resource.urlString)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.appMuted)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.appElevatedSurface.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
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
        .padding(.vertical, 16)
        .background(Color.appBackground)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.appBorder)
                .frame(height: 1)
        }
    }
}
