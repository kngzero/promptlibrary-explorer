import SwiftUI

/// Menu content listing collections as nested submenus that mirror their collection sets.
/// Takes the view model explicitly because menu-bar `Commands` don't inherit the window's environment.
struct CollectionMenuItems: View {
    let vm: ExplorerViewModel
    var parentID: UUID? = nil
    /// A collection shown but not selectable (e.g. the one currently open).
    var disabledID: UUID? = nil
    let onPick: (FileCollection) -> Void

    var body: some View {
        let children = vm.collectionChildren(of: parentID)

        ForEach(children.sets) { set in
            Menu(set.name) {
                CollectionMenuItems(vm: vm, parentID: set.id, disabledID: disabledID, onPick: onPick)
            }
        }

        ForEach(children.collections) { collection in
            Button(collection.name) { onPick(collection) }
                .disabled(collection.id == disabledID)
        }

        if parentID != nil, children.sets.isEmpty, children.collections.isEmpty {
            Text("Empty")
        }
    }
}
