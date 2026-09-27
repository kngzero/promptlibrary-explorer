import SwiftUI

/// Context-menu items for a grid tile / list row: Apply Suggested Tags… and the Stack
/// submenu. Every action first makes the right-clicked item part of the selection.
struct StackContextMenuItems: View {
    @Environment(ExplorerViewModel.self) private var vm
    let item: FileEntry
    let index: Int
    /// The selection as it will be after `ensureSelected`.
    let targets: [FileEntry]

    private func onSelection(_ action: @escaping () -> Void) -> () -> Void {
        { [vm, item, index] in
            ContentItemActions.ensureSelected(item, at: index, vm: vm)
            action()
        }
    }

    private var hasImages: Bool {
        targets.contains { !$0.isDirectory && FileHelpers.isImageFile($0.name) }
    }

    /// The stack all targets are in, when stacks are showing.
    private var stack: FileStack? {
        guard vm.isStackingEnabled else { return nil }
        let paths = targets.filter { !$0.isDirectory }.map(\.path)
        guard let first = paths.first, let stack = vm.stackController.stack(containing: first),
              paths.allSatisfy({ vm.stackController.stack(containing: $0)?.id == stack.id })
        else { return nil }
        return stack
    }

    var body: some View {
        if hasImages {
            Button("Apply Suggested Tags…", action: onSelection { vm.openApplySuggestedTags() })
        }

        if vm.stackScope != nil, !item.isDirectory {
            Menu("Stack") {
                if targets.filter({ !$0.isDirectory }).count >= 2 {
                    Button("Stack Selected", action: onSelection { vm.stackSelection() })
                }
                if let stack {
                    let isExpanded = vm.stackController.isExpanded(stack.id)
                    Button(isExpanded ? "Collapse Stack" : "Expand Stack") {
                        vm.toggleStackExpansion(stack.id)
                    }
                    if targets.count == 1, stack.coverPath != item.path {
                        Button("Set as Cover", action: onSelection { vm.setSelectionAsStackCover() })
                    }
                    Button("Remove from Stack", action: onSelection { vm.removeSelectionFromStack() })
                    Divider()
                    Button("Unstack", action: onSelection { vm.unstackSelection() })
                }
                Divider()
                Toggle("Stack Variants", isOn: Binding(
                    get: { vm.isStackingEnabled },
                    set: { _ in vm.toggleStackingForCurrentListing() }
                ))
            }
        }
    }
}
