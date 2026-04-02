import SwiftUI

struct SettingsView: View {
    @Environment(ExplorerViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    @State private var resultMessage: String?
    @State private var resultTone: ToastType = .info
    @State private var isProcessing = false
    @State private var includeSubfolders = false

    var body: some View {
        @Bindable var vm = vm

        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    appearanceCard

                    currentFolderCard

                    actionCard(
                        title: "Sort Into Dated Folders",
                        description: "Create `YYYY-MM-DD/img`, `YYYY-MM-DD/aoe`, and `YYYY-MM-DD/plib` folders from the current directory contents.",
                        icon: "calendar.badge.clock",
                        accent: Color.appAccent,
                        buttonTitle: "Run Sort",
                        action: performSort
                    )

                    actionCard(
                        title: "Unsort And Flatten",
                        description: "Move organized files back into the current folder. Optionally scan nested dated folders before flattening.",
                        icon: "arrow.up.left.and.arrow.down.right.circle",
                        accent: Color.appAccentHover,
                        buttonTitle: "Run Unsort",
                        action: performUnsort
                    ) {
                        Toggle(isOn: $includeSubfolders) {
                            Label("Scan subfolders during unsort", systemImage: "folder.badge.questionmark")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.appPrimaryText)
                        }
                        .toggleStyle(.checkbox)
                    }

                    if let resultMessage {
                        resultBanner(message: resultMessage, tone: resultTone)
                    }
                }
                .padding(20)
            }

            footer
        }
        .frame(width: 620, height: 520)
        .background(Color.appBackground)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.appElevatedSurface)
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 4) {
                Text("Maintenance Tools")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Color.appPrimaryText)

                Text("Organize and repair the current folder with focused file-management actions.")
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

    private var appearanceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Appearance", systemImage: "circle.lefthalf.filled")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.appAccent)

            Picker(
                "Appearance",
                selection: Binding(
                    get: { vm.appearanceMode },
                    set: { newValue in
                        vm.appearanceMode = newValue
                        vm.persistAppearanceMode()
                    }
                )
            ) {
                ForEach(AppAppearanceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text("Light mode mirrors the dark neutrals into lighter counterparts while keeping the app accent intact.")
                .font(.system(size: 13))
                .foregroundStyle(Color.appMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.appSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.appBorder, lineWidth: 1)
        )
    }

    private var currentFolderCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Current Folder", systemImage: "folder.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.appAccent)

            Text(selectedFolderLabel)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(selectedFolderAvailable ? Color.appPrimaryText : Color.appMuted)
                .lineLimit(2)

            if !selectedFolderAvailable {
                Text("Select a folder in the explorer before running maintenance actions.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.appMuted)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.appSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.appBorder, lineWidth: 1)
        )
    }

    private func actionCard(
        title: String,
        description: String,
        icon: String,
        accent: Color,
        buttonTitle: String,
        action: @escaping () async -> Void,
        @ViewBuilder extraContent: () -> some View = { EmptyView() }
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

            extraContent()

            HStack(spacing: 12) {
                Button {
                    Task { await action() }
                } label: {
                    HStack(spacing: 8) {
                        if isProcessing {
                            ProgressView()
                                .controlSize(.small)
                                .tint(Color.appPrimaryText)
                        }
                        Text(buttonTitle)
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(selectedFolderAvailable ? accent : Color.appElevatedSurface)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!selectedFolderAvailable || isProcessing)

                if isProcessing {
                    Text("Processing…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.appMuted)
                }
            }
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

    private func resultBanner(message: String, tone: ToastType) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: bannerIcon(for: tone))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(bannerColor(for: tone))
                .frame(width: 18)

            Text(message)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.appPrimaryText)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(bannerColor(for: tone).opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(bannerColor(for: tone).opacity(0.35), lineWidth: 1)
        )
    }

    private var footer: some View {
        HStack {
            Spacer()

            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

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

    private var selectedFolderAvailable: Bool {
        vm.selectedFolderPath != nil
    }

    private var selectedFolderLabel: String {
        vm.selectedFolderPath?.path ?? "No folder selected"
    }

    private func bannerColor(for tone: ToastType) -> Color {
        switch tone {
        case .success: return Color.appSuccess
        case .error: return Color.appError
        case .info: return Color.appAccent
        }
    }

    private func bannerIcon(for tone: ToastType) -> String {
        switch tone {
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    private func performSort() async {
        guard let dir = vm.selectedFolderPath else { return }
        isProcessing = true
        defer { isProcessing = false }

        do {
            let result = try FileSystemService.sortFilesIntoDatedSubfolders(directory: dir)
            resultTone = .success
            resultMessage = "Sorted \(result.movedTotal) files: \(result.movedImg) images, \(result.movedAeo) aoe, \(result.movedPlib) plib."
            await vm.refreshFolder()
        } catch {
            resultTone = .error
            resultMessage = "Sort failed: \(error.localizedDescription)"
        }
    }

    private func performUnsort() async {
        guard let dir = vm.selectedFolderPath else { return }
        isProcessing = true
        defer { isProcessing = false }

        do {
            let result = try FileSystemService.unsortFilesIntoCurrentFolder(
                directory: dir,
                includeSubfolders: includeSubfolders
            )
            resultTone = .success
            resultMessage = "Moved \(result.movedTotal) files back: \(result.movedImg) images, \(result.movedAeo) aoe, \(result.movedPlib) plib."
            await vm.refreshFolder()
        } catch {
            resultTone = .error
            resultMessage = "Unsort failed: \(error.localizedDescription)"
        }
    }
}
