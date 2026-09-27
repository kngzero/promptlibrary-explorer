import SwiftUI

/// View ▸ Compare Images (and the grid's context menu): a full page over the
/// content browser and the details panel, like the Similar Images page — the
/// sidebar stays, the browser keeps running underneath and is shown exactly
/// as it was when the page closes (Done, Esc, View ▸ Show Browser, or
/// navigating in the sidebar).
///
/// Inspection only: there is no trash / delete affordance on this page, and
/// the key monitor swallows the browser's keys (Delete, ⇧Delete, arrows…)
/// while it's up.
struct ComparePageView: View {
    @Environment(ExplorerViewModel.self) private var vm
    let model: CompareCanvasModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.appBorder)
            CompareToolbar(model: model)
                .padding(.horizontal, AppSpacing.xl)
                .padding(.vertical, AppSpacing.sm)
                .background(Color.appSurface)
            Divider().background(Color.appBorder)
            CompareCanvasView(model: model)
        }
        .background(Color.appBackground)
        // Navigating the sidebar (folder, collection, smart folder, listing)
        // means "show me the browser": the page makes way.
        .onChange(of: vm.comparePageNavigationKey) { _, _ in
            vm.closeComparePage()
        }
        .onChange(of: vm.isSimilarImagesPageActive) { _, active in
            if active { vm.closeComparePage() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Compare Images")
    }

    private var header: some View {
        HStack(spacing: AppSpacing.md) {
            Image(systemName: "rectangle.split.2x1")
                .font(.appIcon(15, weight: .semibold))
                .foregroundStyle(Color.appAccent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text("Compare Images")
                    .font(.appTitle)
                    .foregroundStyle(Color.appPrimaryText)
                Text(subtitle)
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: AppSpacing.lg)
            // Esc is owned by the key monitor (no key equivalent here).
            Button {
                vm.closeComparePage()
            } label: {
                Text("Done")
                    .font(.appCalloutEmphasis)
            }
            .buttonStyle(AppPrimaryButtonStyle(verticalPadding: AppSpacing.xs))
            .help("Back to the browser (Esc)")
        }
        .padding(.horizontal, AppSpacing.xl)
        .padding(.vertical, AppSpacing.md)
        .background(Color.appSurface)
    }

    private var subtitle: String {
        "\(model.items.count) files · pinch, scroll or ⌘-scroll to zoom, drag to pan, double-click for Fit / 100 %. Every pane follows."
    }
}

/// The Similar Images page's group in the synced compare (the header's
/// Compare toggle): up to four files at a time — the page containing the
/// focused card, so ←/→ move through a larger group.
struct SimilarGroupCompareView: View {
    @Environment(ExplorerViewModel.self) private var vm
    let set: SimilarSet

    @State private var model: CompareCanvasModel?

    private var window: (paths: [String], start: Int) {
        CompareEligibility.window(of: set.paths, containing: vm.similarImages.focusedPath)
    }

    var body: some View {
        let window = window
        VStack(spacing: 0) {
            HStack(spacing: AppSpacing.md) {
                if let model {
                    CompareToolbar(model: model)
                }
                if set.paths.count > CompareEligibility.maximumCount {
                    Text("Files \(window.start + 1)–\(window.start + window.paths.count) of \(set.paths.count) · ← → move on")
                        .font(.appCaption)
                        .foregroundStyle(Color.appMuted)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, AppSpacing.xl)
            .padding(.vertical, AppSpacing.sm)
            Divider().background(Color.appBorder)
            if let model, model.paths == window.paths {
                CompareCanvasView(model: model)
            } else {
                Color.appCanvasBackground
            }
        }
        .task(id: window.paths) {
            guard window.paths.count >= CompareEligibility.minimumCount else {
                model = nil
                return
            }
            if model?.paths != window.paths {
                let previous = model
                let next = CompareCanvasModel(paths: window.paths)
                if let previous {
                    // Keep the mode and framing when paging through a group.
                    next.state.mode = previous.state.mode
                    next.state.framing = previous.state.framing
                    next.state.wipeOrientation = previous.state.wipeOrientation
                    previous.cancelLoads()
                }
                model = next
            }
        }
        .onDisappear { model?.cancelLoads() }
    }
}

/// The Similar Images group header's "Compare" toggle: synced compare
/// (zoom / pan / wipe) instead of the side-by-side cards.
struct SimilarCompareToggle: View {
    @Bindable private var viewing = ViewingController.shared

    var body: some View {
        Button {
            viewing.similarPageCompare.toggle()
        } label: {
            Label("Compare", systemImage: "rectangle.split.2x1")
                .font(.appCaption)
        }
        .buttonStyle(AppLabeledButtonStyle(
            height: 24,
            horizontalPadding: AppSpacing.md,
            restingForeground: viewing.similarPageCompare ? Color.appAccent : nil
        ))
        .help(viewing.similarPageCompare
            ? "Back to the cards"
            : "Compare these files with synced zoom and pan, or an A/B wipe")
        .accessibilityLabel("Compare")
        .accessibilityValue(viewing.similarPageCompare ? "On" : "Off")
    }
}
