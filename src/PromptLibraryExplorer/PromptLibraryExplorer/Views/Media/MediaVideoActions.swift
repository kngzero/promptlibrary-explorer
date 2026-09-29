import AVFoundation
import SwiftUI

/// Video tools in the lightbox's action area: Save Frame…, Copy Frame, Save Frame Strip…
/// and Trim…. Frame actions use the player's current time (the frame on screen).
struct MediaLightboxVideoActions: View {
    let videoURL: URL
    let player: AVPlayer
    let displayName: String

    private var media: MediaController { MediaController.shared }

    private var currentSeconds: Double {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? max(seconds, 0) : 0
    }

    var body: some View {
        VStack(spacing: AppSpacing.sm) {
            HStack(spacing: AppSpacing.sm) {
                toolButton("Save Frame…", icon: "photo.badge.arrow.down", help: "Save the frame on screen at full resolution (PNG or JPEG)") {
                    player.pause()
                    media.saveFrame(of: videoURL, at: currentSeconds, displayName: displayName)
                }
                toolButton("Copy Frame", icon: "doc.on.clipboard", help: "Copy the frame on screen to the clipboard") {
                    player.pause()
                    media.copyFrame(of: videoURL, at: currentSeconds)
                }
            }
            HStack(spacing: AppSpacing.sm) {
                toolButton("Frame Strip…", icon: "rectangle.split.3x1", help: "Save a contact strip of evenly spaced frames") {
                    media.saveFrameStrip(of: videoURL, displayName: displayName)
                }
                toolButton("Trim…", icon: "timeline.selection", help: "Trim and export a clip as MP4 or an animated GIF") {
                    let start = currentSeconds
                    player.pause()
                    media.openTrim(for: videoURL, startTime: start)
                }
                .disabled(media.isExporting)
            }
        }
        .disabled(media.isSavingFrame)
    }

    private func toolButton(_ title: String, icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: icon)
                    .font(.appCallout)
                Text(title)
                    .font(.appIcon(12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(Color.appPrimaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppSpacing.md)
            .background(Color.appElevatedSurface, in: RoundedRectangle(cornerRadius: AppRadius.md))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .strokeBorder(Color.appControlBorder, lineWidth: 1)
            )
        }
        .buttonStyle(AppAdaptiveButtonStyle())
        .help(help)
        .accessibilityLabel(title)
    }
}

/// Context-menu items for video files (Save Middle Frame, Trim & Export Clip…).
struct MediaItemMenuItems: View {
    @Environment(ExplorerViewModel.self) private var vm
    let item: FileEntry

    var body: some View {
        if !item.isDirectory, FileHelpers.isVideoFile(item.name) {
            Button("Save Middle Frame") { vm.saveMiddleFrames(for: item) }
                .disabled(MediaController.shared.isSavingFrame)
            Button("Trim & Export Clip…") { vm.openTrim(for: item) }
                .disabled(MediaController.shared.isExporting)
        } else if !item.isDirectory, FileHelpers.isAudioFile(item.name) {
            Button("Trim & Export Audio…") { vm.openTrim(for: item) }
                .disabled(MediaController.shared.isExporting)
        }
    }
}

/// Installs the media controller's hooks into the view model (applied once in the App
/// file). The Trim page itself is an overlay in MainContentView.
struct MediaSheetsHost: ViewModifier {
    @Environment(ExplorerViewModel.self) private var vm

    func body(content: Content) -> some View {
        content
            .onAppear { vm.installMediaHooks() }
    }
}

extension View {
    func mediaSheetsHost() -> some View {
        modifier(MediaSheetsHost())
    }
}
