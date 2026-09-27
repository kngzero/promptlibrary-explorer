import SwiftUI

// MARK: - Tip layer

/// Draws the active contextual tip over the main window (above the browser and the
/// lightbox) and notices the moments tips are for. Mounted once by MainContentView,
/// which passes the browser columns' sizes so a tip can sit beside the right one.
/// Only the card takes clicks; the rest of the layer is transparent to them.
struct OnboardingTipLayer: View {
    @Environment(ExplorerViewModel.self) private var vm
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var tips: OnboardingTipsController { OnboardingTipsController.shared }

    /// Content column, details column (0 when hidden).
    let contentWidth: CGFloat
    let detailWidth: CGFloat

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let tip = tips.activeTip, vm.isTipRelevant(tip) {
                    placed(tip, in: proxy.size)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
                        .id(tip)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: tips.activeTip)
        }
        .onAppear { vm.configureOnboardingTips() }
        // The moments tips are for.
        .onChange(of: vm.selectedPromptEntry?.sourcePath) { _, _ in
            if vm.selectedIndices.count == 1, !(vm.selectedPromptEntry?.prompt.isEmpty ?? true) {
                tips.request(.promptSelected)
            }
        }
        .onChange(of: vm.lightboxOpen) { _, open in
            if open {
                tips.request(.lightboxOpened)
            } else {
                tips.withdraw(.lightboxOpened)
            }
            tips.evaluate()
        }
        .onChange(of: vm.selectedIndices) { _, indices in
            if (2...4).contains(indices.count), vm.canCompareImages {
                tips.request(.compareSelection)
            } else {
                tips.withdraw(.compareSelection)
            }
            if indices.count == 1, vm.selectedItems.contains(where: { FileHelpers.isVideoFile($0.name) }) {
                tips.request(.videoSelected)
            } else {
                tips.withdraw(.videoSelected)
            }
            tips.evaluate()
        }
        .onChange(of: vm.processedFolderContents.count) { _, _ in
            if vm.listingImageCount > 50 { tips.request(.largeFolder) }
        }
        .onChange(of: vm.collections.count) { old, new in
            if new > old { tips.request(.firstCollection) }
        }
        .onChange(of: vm.isLibraryIndexing) { wasIndexing, isIndexing in
            if wasIndexing, !isIndexing { tips.request(.indexingFinished) }
        }
        .onChange(of: ExportController.shared.isRunning) { wasRunning, isRunning in
            if wasRunning, !isRunning { tips.request(.firstExport) }
        }
        .onChange(of: vm.isSimilarImagesPageActive) { _, _ in tips.evaluate() }
        .onChange(of: vm.isComparePageActive) { _, _ in tips.evaluate() }
    }

    // MARK: Placement

    private func placed(_ tip: OnboardingTip, in size: CGSize) -> some View {
        let detail = detailWidth > 0 ? detailWidth + 1 : 0
        let contentTrailingInset = min(max(0, detail), size.width)
        let contentLeading = contentWidth > 0 ? max(0, size.width - contentTrailingInset - contentWidth) : 0
        let edge = AppSpacing.xl

        let card = OnboardingTipCard(tip: tip, pointer: pointer(for: tip.placement))
        switch tip.placement {
        case .contentBottomLeading:
            return AnyView(card
                .padding(.leading, contentLeading + edge)
                // Clear of the status bar.
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading))
        case .contentTopTrailing:
            return AnyView(card
                .padding(.trailing, contentTrailingInset + edge)
                .padding(.top, AppSpacing.lg)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing))
        case .besideDetailsPanel:
            // Pointing at the details panel; without one, the content corner.
            if detail > 0 {
                return AnyView(card
                    .padding(.trailing, contentTrailingInset + AppSpacing.md)
                    .padding(.top, 96)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing))
            }
            return AnyView(card
                .padding(.leading, contentLeading + edge)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading))
        case .lightboxTopTrailing:
            return AnyView(card
                .padding(.trailing, edge)
                .padding(.top, 60)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing))
        }
    }

    private func pointer(for placement: OnboardingTipPlacement) -> OnboardingTipCard.Pointer {
        switch placement {
        case .contentBottomLeading: return .none
        case .contentTopTrailing: return .up
        case .besideDetailsPanel: return detailWidth > 0 ? .trailing : .none
        case .lightboxTopTrailing: return .up
        }
    }
}

// MARK: - Card

/// A small, dismissible tip: symbol, title, two or three lines, "Got it", an
/// optional action and "Don't Show Tips".
struct OnboardingTipCard: View {
    enum Pointer { case none, up, trailing }

    @Environment(ExplorerViewModel.self) private var vm
    let tip: OnboardingTip
    var pointer: Pointer = .none

    private var tips: OnboardingTipsController { OnboardingTipsController.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(alignment: .top, spacing: AppSpacing.md) {
                ZStack {
                    Circle().fill(Color.appAccent.opacity(0.16))
                    Image(systemName: tip.symbol)
                        .font(.appIcon(13, weight: .semibold))
                        .foregroundStyle(Color.appAccent)
                }
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text(tip.title)
                        .font(.appHeadline)
                        .foregroundStyle(Color.appPrimaryText)
                    Text(tip.message)
                        .font(.appCallout)
                        .foregroundStyle(Color.appMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Button {
                    tips.dismissActive()
                    vm.openHelp(focus: .entry(tip.helpEntryID))
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.appCallout)
                }
                .buttonStyle(AppIconButtonStyle(width: 22, height: 22, showsRestingChrome: false))
                .help("Learn more in Help")
                .accessibilityLabel("Learn more in Help")
            }

            HStack(spacing: AppSpacing.md) {
                Button("Don't Show Tips") { tips.disableAll() }
                    .buttonStyle(.plain)
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
                    .help("Turn off all tips (Help ▸ Show Tips turns them back on)")

                Spacer(minLength: AppSpacing.md)

                if let action = tip.action, vm.canPerform(action) {
                    Button(action.tryItTitle) {
                        tips.dismissActive()
                        vm.perform(action)
                    }
                    .buttonStyle(AppLabeledButtonStyle(height: 24, horizontalPadding: AppSpacing.md))
                    .font(.appCaption)
                }

                Button("Got it") { tips.dismissActive() }
                    .buttonStyle(AppPrimaryButtonStyle(
                        foreground: .appOnAccent,
                        font: .appCaptionEmphasis,
                        horizontalPadding: AppSpacing.lg,
                        verticalPadding: AppSpacing.xs
                    ))
            }
        }
        .padding(AppSpacing.lg)
        .frame(width: 320, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .fill(Color.appElevatedSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .strokeBorder(Color.appAccent.opacity(0.35), lineWidth: 1)
        )
        .overlay(alignment: pointerAlignment) { pointerView }
        .shadow(color: Color.appShadowColor, radius: 14, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tip: \(tip.title)")
    }

    private var pointerAlignment: Alignment {
        switch pointer {
        case .none, .up: return .topTrailing
        case .trailing: return .topTrailing
        }
    }

    @ViewBuilder
    private var pointerView: some View {
        switch pointer {
        case .none:
            EmptyView()
        case .up:
            TipPointer()
                .fill(Color.appElevatedSurface)
                .overlay(TipPointer().stroke(Color.appAccent.opacity(0.35), lineWidth: 1))
                .frame(width: 14, height: 7)
                .offset(x: -AppSpacing.xxl, y: -6.5)
                .accessibilityHidden(true)
        case .trailing:
            TipPointer()
                .fill(Color.appElevatedSurface)
                .overlay(TipPointer().stroke(Color.appAccent.opacity(0.35), lineWidth: 1))
                .frame(width: 14, height: 7)
                .rotationEffect(.degrees(90))
                .offset(x: 10, y: AppSpacing.xxl)
                .accessibilityHidden(true)
        }
    }
}

/// An upward-pointing notch (open at the bottom, so it merges with the card).
private struct TipPointer: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return path
    }
}

// MARK: - Settings row

/// Settings ▸ Appearance ▸ Tips: the global switch and Reset Tips.
struct OnboardingTipsSettingsCard: View {
    @Environment(ExplorerViewModel.self) private var vm

    var body: some View {
        SettingsCard(title: "Tips & Tour", icon: "lightbulb") {
            SettingsToggleRow(
                title: "Show tips as I use the app",
                detail: "A small tip appears once, the first time a feature becomes useful — never while a sheet is open or while you type, and at most one a minute.",
                isOn: Binding(
                    get: { OnboardingTipsController.shared.tipsEnabled },
                    set: { OnboardingTipsController.shared.tipsEnabled = $0 }
                )
            )

            HStack(spacing: AppSpacing.md) {
                Button("Reset Tips") { vm.resetTips() }
                    .buttonStyle(AppLabeledButtonStyle())
                    .help("Show every tip again")
                Button("Welcome Tour…") { vm.presentWelcomeTour() }
                    .buttonStyle(AppLabeledButtonStyle())
                    .help("Replay the welcome tour in the main window")
                Spacer(minLength: 0)
            }
        }
    }
}
