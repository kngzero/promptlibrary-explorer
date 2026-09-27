import SwiftUI

/// Presents the export and contact-sheet sheets on the main window. Applied once
/// in the App file, so MainContentView stays untouched.
struct ExportSheetsHost: ViewModifier {
    @Environment(ExplorerViewModel.self) private var vm
    @Bindable private var controller = ExportController.shared

    func body(content: Content) -> some View {
        content
            .sheet(item: $controller.exportRequest) { request in
                ExportSheetView(request: request)
                    .environment(vm)
            }
            .sheet(item: $controller.contactSheetRequest) { request in
                ContactSheetView(request: request)
                    .environment(vm)
            }
    }
}

extension View {
    func exportSheetsHost() -> some View {
        modifier(ExportSheetsHost())
    }
}
