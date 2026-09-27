import SwiftUI

// MARK: - Tile / row badge

/// Small cloud badge for online-only files (downloading: a spinner). Nothing for
/// local files.
struct CloudFileBadge: View {
    let item: FileEntry
    var side: CGFloat = 20

    private var cloud: CloudFileController { .shared }

    var body: some View {
        if cloud.isDownloading(item.path) {
            ProgressView()
                .controlSize(.mini)
                .frame(width: side, height: side)
                .background(Color.appOverlaySurface, in: Circle())
                .overlay(Circle().strokeBorder(Color.appOverlayStroke, lineWidth: 1))
                .help("Downloading from the cloud")
                .accessibilityLabel("Downloading")
        } else if cloud.isCloudOnly(item) {
            Image(systemName: "icloud.and.arrow.down")
                .font(.system(size: side * 0.5, weight: .semibold))
                .foregroundStyle(Color.appPrimaryText)
                .frame(width: side, height: side)
                .background(Color.appOverlaySurface, in: Circle())
                .overlay(Circle().strokeBorder(Color.appOverlayStroke, lineWidth: 1))
                .help("Online only: not downloaded to this Mac. Right-click ▸ Download to fetch it.")
                .accessibilityLabel("Online only")
        }
    }
}

/// Inline icon for list rows.
struct CloudFileInlineIcon: View {
    let item: FileEntry
    private var cloud: CloudFileController { .shared }

    var body: some View {
        if cloud.isDownloading(item.path) {
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel("Downloading")
        } else if cloud.isCloudOnly(item) {
            Image(systemName: "icloud.and.arrow.down")
                .font(.appFootnote)
                .foregroundStyle(Color.appMuted)
                .help("Online only: not downloaded to this Mac")
                .accessibilityLabel("Online only")
        }
    }
}

// MARK: - Context menu

/// Download / Make Available Offline… for the targets that are online-only.
struct CloudItemMenuItems: View {
    @Environment(ExplorerViewModel.self) private var vm
    let targets: [FileEntry]

    var body: some View {
        let cloudOnly = vm.cloudOnlyItems(in: targets)
        if !cloudOnly.isEmpty {
            Button(cloudOnly.count == 1 ? "Download" : "Download \(cloudOnly.count) Files") {
                vm.downloadCloudFiles(cloudOnly)
            }
            Button("Make Available Offline…") {
                vm.makeCloudFilesAvailableOffline(cloudOnly)
            }
        }
    }
}

// MARK: - Lightbox

/// Covers the lightbox viewport for an online-only file: "Download to view" (or the
/// download's progress). With "Download files automatically when opened" on, the
/// download starts by itself — opening the lightbox is an explicit open.
struct LightboxCloudOverlay: View {
    let item: FileEntry?
    private var cloud: CloudFileController { .shared }

    var body: some View {
        if let item, !item.isDirectory, cloud.isDownloading(item.path) || cloud.isCloudOnly(path: item.path) {
            content(for: item)
                .task(id: item.path) {
                    cloud.downloadForExplicitOpen(item.url)
                }
        }
    }

    @ViewBuilder
    private func content(for item: FileEntry) -> some View {
        let downloading = cloud.isDownloading(item.path)
        VStack(spacing: AppSpacing.lg) {
            Image(systemName: downloading ? "icloud.and.arrow.down" : "icloud")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(Color.appMuted)
                .accessibilityHidden(true)
            Text(downloading ? "Downloading \u{201C}\(item.name)\u{201D}…" : "\u{201C}\(item.name)\u{201D} is online only")
                .font(.appHeadline)
                .foregroundStyle(Color.appPrimaryText)
                .multilineTextAlignment(.center)
            Text(downloading
                 ? "It opens here as soon as it's on this Mac."
                 : "It isn't downloaded to this Mac yet. Nothing is fetched until you ask.")
                .font(.appCallout)
                .foregroundStyle(Color.appMuted)
                .multilineTextAlignment(.center)
            if downloading {
                ProgressView()
                    .controlSize(.small)
                Button("Cancel") { cloud.cancel(item.path) }
                    .buttonStyle(AppLabeledButtonStyle())
            } else {
                Button("Download to View") { cloud.download([item.url], announce: false) }
                    .buttonStyle(AppPrimaryButtonStyle())
                if let failure = cloud.failures[item.path] {
                    Text(failure)
                        .font(.appCaption)
                        .foregroundStyle(Color.appError)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding(AppSpacing.xxxl)
        .frame(maxWidth: 420)
        .background(Color.appOverlaySurface, in: RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous).strokeBorder(Color.appOverlayStroke, lineWidth: 1))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}
