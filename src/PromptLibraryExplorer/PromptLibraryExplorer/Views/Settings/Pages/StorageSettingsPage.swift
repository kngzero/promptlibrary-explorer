import SwiftUI

struct StorageSettingsPage: View {
    @Environment(ExplorerViewModel.self) private var vm

    @State private var cacheStats: CacheStatistics?
    @State private var isMeasuringCache = false
    @State private var isClearingCache = false
    @State private var resultMessage: String?

    var body: some View {
        SettingsCard {
            HStack(alignment: .center, spacing: AppSpacing.md) {
                Label("Cache", systemImage: "internaldrive.fill")
                    .font(.appHeadline)
                    .foregroundStyle(Color.appAccent)

                Spacer(minLength: 0)

                if isMeasuringCache {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        Task { await refreshCacheStats() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.appCalloutEmphasis)
                    }
                    .buttonStyle(AppIconButtonStyle(width: 24, height: 24, cornerRadius: AppRadius.sm, showsRestingChrome: false))
                    .help("Recalculate cache usage")
                    .accessibilityLabel("Recalculate cache usage")
                }
            }

            if let stats = cacheStats {
                VStack(spacing: AppSpacing.md) {
                    SettingsStatRow(
                        label: "Thumbnails on disk",
                        detail: stats.thumbnailFileCount == 1 ? "1 file" : "\(stats.thumbnailFileCount) files",
                        value: stats.formattedDiskSize
                    )
                    SettingsStatRow(
                        label: "Parsed prompt files",
                        detail: ".plib and .aoe",
                        value: entryLabel(stats.plibEntries + stats.aoeEntries)
                    )
                    SettingsStatRow(
                        label: "Media metadata",
                        detail: "images and audio",
                        value: entryLabel(stats.imageMetadataEntries + stats.audioMetadataEntries)
                    )
                    SettingsStatRow(
                        label: "Prompt search index",
                        detail: "used by content search",
                        value: entryLabel(stats.promptIndexEntries)
                    )
                }

                SettingsFootnote("Clearing removes cached thumbnails and parsed metadata. Your files, tags, ratings, and smart folders are untouched — thumbnails regenerate as you browse.")

                HStack(spacing: AppSpacing.lg) {
                    SettingsFilledButton(
                        title: "Clear Cache",
                        tint: Color.appError,
                        isBusy: isClearingCache,
                        isEnabled: !stats.isEmpty,
                        action: clearCache
                    )

                    if stats.isEmpty {
                        Text("Cache is already empty.")
                            .font(.appIcon(13, weight: .medium))
                            .foregroundStyle(Color.appMuted)
                    }
                }
            } else {
                SettingsFootnote("Measuring cache usage…")
            }
        }
        .task { await refreshCacheStats() }

        if let resultMessage {
            SettingsResultBanner(message: resultMessage, tone: .success)
        }
    }

    private func entryLabel(_ count: Int) -> String {
        count == 1 ? "1 entry" : "\(count) entries"
    }

    private func refreshCacheStats() async {
        isMeasuringCache = true
        defer { isMeasuringCache = false }
        cacheStats = await CacheService.statistics()
    }

    private func clearCache() async {
        let before = cacheStats
        isClearingCache = true
        defer { isClearingCache = false }

        await CacheService.clearAll()

        // Repopulate the current view so thumbnails and metadata come back immediately,
        // then report what the caches hold now rather than a momentary zero.
        await vm.refreshFolder()
        await refreshCacheStats()

        if let before {
            resultMessage = "Cleared \(before.formattedDiskSize) of thumbnails and \(entryLabel(before.memoryEntryCount)) of cached metadata."
        } else {
            resultMessage = "Cache cleared."
        }
    }
}
