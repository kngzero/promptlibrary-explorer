import SwiftUI

/// The welcome tour: a short, skippable, paged sheet. Shown on first launch
/// (`OnboardingHost`) and from Help ▸ Welcome Tour…. Keys are sheet-local:
/// ← / → page, Return is Next (Done on the last page), Esc skips. The app-wide
/// key monitors stand down while a sheet is key.
struct WelcomeTourView: View {
    @Environment(ExplorerViewModel.self) private var vm
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var state = WelcomeTourState()
    /// Direction of the last page change, for the slide transition.
    @State private var forward = true

    private var page: WelcomeTourPage { state.page ?? .welcome }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                pageContent(page)
                    .id(page)
                    .transition(pageTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            footer
        }
        .frame(width: 640, height: 500)
        .background(Color.appBackground)
        .background { keyButtons }
    }

    // MARK: Page

    private func pageContent(_ page: WelcomeTourPage) -> some View {
        VStack(spacing: 0) {
            TourIllustration(page: page)
                .frame(height: 230)

            VStack(spacing: AppSpacing.lg) {
                Text(page.headline)
                    .font(.appIcon(22, weight: .bold))
                    .foregroundStyle(Color.appPrimaryText)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)

                Text(page.body)
                    .font(.appIcon(14))
                    .foregroundStyle(Color.appMuted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 500)

                if let command = page.tryIt {
                    Button {
                        OnboardingController.shared.finishTour(running: command)
                    } label: {
                        Label("Try it: \(command.tryItTitle)", systemImage: "arrow.up.forward.app")
                            .font(.appCalloutEmphasis)
                    }
                    .buttonStyle(AppLabeledButtonStyle(height: 28, horizontalPadding: AppSpacing.lg))
                    .disabled(!vm.canPerform(command))
                    .help(vm.canPerform(command)
                        ? "Close the tour and open \(command.locationText)"
                        : vm.unavailableHint(for: command))
                }
            }
            .padding(.horizontal, AppSpacing.xxxl)
            .padding(.top, AppSpacing.xxl)

            Spacer(minLength: 0)
        }
    }

    private var pageTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().background(Color.appBorder)
            HStack(spacing: AppSpacing.md) {
                Button("Skip Tour") { finish() }
                    .keyboardShortcut(.cancelAction)
                    .help("Close the tour (Esc). Help ▸ Welcome Tour… shows it again.")

                Spacer(minLength: AppSpacing.md)

                pageDots

                Spacer(minLength: AppSpacing.md)

                Button("Back") { apply(.left) }
                    .disabled(state.isFirst)

                Button(state.isLast ? "Done" : "Next") { apply(.returnKey) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, AppSpacing.xl)
            .padding(.vertical, AppSpacing.lg)
            .background(Color.appSurface)
        }
    }

    private var pageDots: some View {
        HStack(spacing: AppSpacing.sm) {
            ForEach(WelcomeTourPage.allCases) { item in
                Button {
                    forward = item.rawValue >= state.index
                    withAnimation(animation) { state.go(to: item.rawValue) }
                } label: {
                    Capsule()
                        .fill(item.rawValue == state.index ? Color.appAccent : Color.appControlBorder)
                        .frame(width: item.rawValue == state.index ? 18 : 7, height: 7)
                        .contentShape(Rectangle().inset(by: -4))
                }
                .buttonStyle(.plain)
                .help(item.headline)
                .accessibilityLabel("Page \(item.rawValue + 1) of \(state.pageCount): \(item.headline)")
                .accessibilityAddTraits(item.rawValue == state.index ? .isSelected : [])
            }
        }
    }

    /// ← and → as real (hidden) buttons, so they work whatever has focus in the sheet.
    private var keyButtons: some View {
        Group {
            Button("Previous Page") { apply(.left) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("Next Page") { apply(.right) }
                .keyboardShortcut(.rightArrow, modifiers: [])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: Actions

    private var animation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.22)
    }

    private func apply(_ key: WelcomeTourState.Key) {
        var next = state
        let outcome = next.handle(key)
        switch outcome {
        case .moved:
            forward = next.index > state.index
            withAnimation(animation) { state = next }
        case .finish, .skip:
            finish()
        case .ignored:
            break
        }
    }

    private func finish() {
        OnboardingController.shared.finishTour()
    }
}

// MARK: - Illustration

/// SF Symbols on the app's accent: a hero symbol in a tile, supporting symbols
/// around it and keycaps where the keys are the point. No external images.
private struct TourIllustration: View {
    let page: WelcomeTourPage

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.appAccent.opacity(0.20), Color.appAccent.opacity(0.04)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Soft rings behind the hero.
            Circle()
                .strokeBorder(Color.appAccent.opacity(0.14), lineWidth: 1)
                .frame(width: 190, height: 190)
            Circle()
                .strokeBorder(Color.appAccent.opacity(0.08), lineWidth: 1)
                .frame(width: 280, height: 280)

            ForEach(Array(page.accessorySymbols.enumerated()), id: \.offset) { index, symbol in
                accessory(symbol)
                    .offset(offset(for: index, count: page.accessorySymbols.count))
            }

            VStack(spacing: AppSpacing.lg) {
                ZStack {
                    RoundedRectangle(cornerRadius: AppRadius.xxl, style: .continuous)
                        .fill(Color.appElevatedSurface)
                        .shadow(color: Color.appShadowColor, radius: 12, y: 6)
                    RoundedRectangle(cornerRadius: AppRadius.xxl, style: .continuous)
                        .strokeBorder(Color.appAccent.opacity(0.35), lineWidth: 1)
                    Image(systemName: page.symbol)
                        .font(.appIcon(44, weight: .medium))
                        .foregroundStyle(Color.appAccent)
                        .symbolRenderingMode(.hierarchical)
                }
                .frame(width: 96, height: 96)

                if !page.keycaps.isEmpty {
                    HStack(spacing: AppSpacing.sm) {
                        ForEach(page.keycaps, id: \.self) { key in
                            Text(key)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.appPrimaryText)
                                .padding(.horizontal, AppSpacing.md)
                                .padding(.vertical, AppSpacing.xs)
                                .background(
                                    RoundedRectangle(cornerRadius: AppRadius.sm)
                                        .fill(Color.appBackground)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: AppRadius.sm)
                                        .strokeBorder(Color.appControlBorder, lineWidth: 1)
                                )
                        }
                    }
                }
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }

    private func accessory(_ symbol: String) -> some View {
        ZStack {
            Circle().fill(Color.appSurface)
            Circle().strokeBorder(Color.appBorder, lineWidth: 1)
            Image(systemName: symbol)
                .font(.appIcon(15, weight: .medium))
                .foregroundStyle(Color.appMuted)
        }
        .frame(width: 38, height: 38)
    }

    /// Either side of the hero, clear of the keycap row below it.
    private static let slots: [CGSize] = [
        CGSize(width: -165, height: -48),
        CGSize(width: 165, height: -48),
        CGSize(width: -140, height: 58),
        CGSize(width: 140, height: 58),
    ]

    private func offset(for index: Int, count: Int) -> CGSize {
        Self.slots[index % Self.slots.count]
    }
}
