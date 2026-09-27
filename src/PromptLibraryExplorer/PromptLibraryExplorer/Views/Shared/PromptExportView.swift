import SwiftUI

/// Copy-as menu for a prompt. Formatting lives in PromptFormatService so the
/// menu, the Edit > Copy As commands and batch copies share one implementation.
struct PromptExportMenu: View {
    let entry: PromptEntry
    var title: String = "Export"
    var onCopy: ((String) -> Void)?

    var body: some View {
        Menu {
            ForEach(PromptCopyFormat.allCases) { format in
                Button {
                    ClipboardService.copyString(PromptFormatService.format(entry, as: format))
                    onCopy?(format.title)
                } label: {
                    Label(format.title, systemImage: format.systemImage)
                }
            }
        } label: {
            HStack(spacing: AppSpacing.xs) {
                Image(systemName: "square.on.square")
                    .font(.appCaption)
                Text(title)
                    .font(.appIcon(11, weight: .medium))
            }
            .foregroundStyle(Color.appMuted)
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.xs)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.sm)
                    .fill(Color.appElevatedSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.sm)
                    .strokeBorder(Color.appBorder, lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
