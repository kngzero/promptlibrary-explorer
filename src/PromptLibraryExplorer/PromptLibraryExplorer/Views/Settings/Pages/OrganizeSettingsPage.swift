import SwiftUI

struct OrganizeSettingsPage: View {
    @Environment(ExplorerViewModel.self) private var vm

    @State private var resultMessage: String?
    @State private var resultTone: ToastType = .info
    @State private var isProcessing = false
    @State private var includeSubfolders = false

    var body: some View {
        SettingsCard(title: "Current Folder", icon: "folder.fill") {
            Text(selectedFolderLabel)
                .font(.appIcon(15, weight: .medium))
                .foregroundStyle(selectedFolderAvailable ? Color.appPrimaryText : Color.appMuted)
                .lineLimit(2)

            if !selectedFolderAvailable {
                SettingsFootnote("Select a folder in the explorer before running these actions.")
            }
        }

        SettingsActionCard(
            title: "Sort Into Dated Folders",
            description: "Create `YYYY-MM-DD/img`, `YYYY-MM-DD/aoe`, and `YYYY-MM-DD/plib` folders from the current directory contents.",
            icon: "calendar.badge.clock",
            accent: Color.appAccent,
            buttonTitle: "Run Sort",
            isBusy: isProcessing,
            isEnabled: selectedFolderAvailable,
            action: performSort
        )

        SettingsActionCard(
            title: "Unsort And Flatten",
            description: "Move organized files back into the current folder. Optionally scan nested dated folders before flattening.",
            icon: "arrow.up.left.and.arrow.down.right.circle",
            accent: Color.appAccentHover,
            buttonTitle: "Run Unsort",
            isBusy: isProcessing,
            isEnabled: selectedFolderAvailable,
            action: performUnsort
        ) {
            SettingsToggleRow(
                title: "Scan subfolders during unsort",
                isOn: $includeSubfolders
            )
        }

        if let resultMessage {
            SettingsResultBanner(message: resultMessage, tone: resultTone)
        }
    }

    private var selectedFolderAvailable: Bool {
        vm.selectedFolderPath != nil
    }

    private var selectedFolderLabel: String {
        vm.selectedFolderPath?.path ?? "No folder selected"
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
