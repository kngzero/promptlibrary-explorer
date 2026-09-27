import SwiftUI

struct FileOperationsSettingsPage: View {
    @Environment(ExplorerViewModel.self) private var vm

    var body: some View {
        SettingsCard(title: "Deleting", icon: "trash") {
            SettingsToggleRow(
                title: "Ask before moving files to the Trash",
                detail: "Permanent deletes always ask, whatever this is set to.",
                isOn: confirmBeforeTrashBinding
            )
        }

        SettingsCard(title: "Name Collisions", icon: "doc.on.doc") {
            SettingsFootnote("When a file arriving by drop or move is already named that in the destination:")

            SettingsChoiceRow(
                options: DuplicateNamePolicy.allCases,
                title: \.title,
                explanation: \.explanation,
                selection: duplicateNamePolicyBinding
            )
        }

        SettingsCard(title: "Dragging Out To Other Apps", icon: "arrow.up.forward.app") {
            SettingsChoiceRow(
                options: ExternalDragOperation.allCases,
                title: \.title,
                explanation: \.explanation,
                selection: externalDragOperationBinding
            )
        }
    }

    private var confirmBeforeTrashBinding: Binding<Bool> {
        Binding(
            get: { vm.confirmBeforeTrash },
            set: { newValue in
                vm.confirmBeforeTrash = newValue
                vm.persistConfirmBeforeTrash()
            }
        )
    }

    private var duplicateNamePolicyBinding: Binding<DuplicateNamePolicy> {
        Binding(
            get: { vm.duplicateNamePolicy },
            set: { newValue in
                vm.duplicateNamePolicy = newValue
                vm.persistDuplicateNamePolicy()
            }
        )
    }

    private var externalDragOperationBinding: Binding<ExternalDragOperation> {
        Binding(
            get: { vm.externalDragOperation },
            set: { newValue in
                vm.externalDragOperation = newValue
                vm.persistExternalDragOperation()
            }
        )
    }
}
