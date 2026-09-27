import AppKit
import SwiftUI

/// The comparison itself: 2–4 panes with synced zoom and pan, or an A/B wipe
/// of two. Used by the Compare page and inline on the Similar Images page.
///
/// Pinch, mouse wheel or ⌘-scroll zoom around the pointer; drag (or a
/// two-finger scroll) pans every pane together; double-click toggles Fit and
/// 100 %. No deletion affordance anywhere.
struct CompareCanvasView: View {
    @Environment(ExplorerViewModel.self) private var vm
    @Environment(\.displayScale) private var displayScale
    let model: CompareCanvasModel

    private static let paneSpacing: CGFloat = 2

    var body: some View {
        GeometryReader { geometry in
            Group {
                switch model.state.mode {
                case .sideBySide: sideBySide(size: geometry.size)
                case .wipe: wipe(size: geometry.size)
                }
            }
            .onAppear { syncViewport(total: geometry.size) }
            .onChange(of: geometry.size) { _, size in syncViewport(total: size) }
            .onChange(of: model.state.mode) { _, _ in syncViewport(total: geometry.size) }
        }
        .background(Color.appCanvasBackground)
        .onAppear { model.backingScale = displayScale }
        .onChange(of: displayScale) { _, scale in model.backingScale = scale }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Comparison of \(model.items.count) files")
    }

    private func paneSize(total: CGSize) -> CGSize {
        let grid = CompareGeometry.paneGrid(count: model.items.count, size: total)
        return CGSize(
            width: max(1, (total.width - Self.paneSpacing * CGFloat(grid.columns - 1)) / CGFloat(grid.columns)),
            height: max(1, (total.height - Self.paneSpacing * CGFloat(grid.rows - 1)) / CGFloat(grid.rows))
        )
    }

    private func syncViewport(total: CGSize) {
        let size = model.state.mode == .wipe ? total : paneSize(total: total)
        if model.paneViewport != size { model.paneViewport = size }
    }

    // MARK: Side by side

    private func sideBySide(size: CGSize) -> some View {
        let grid = CompareGeometry.paneGrid(count: model.items.count, size: size)
        let pane = paneSize(total: size)
        return VStack(spacing: Self.paneSpacing) {
            ForEach(0..<grid.rows, id: \.self) { row in
                HStack(spacing: Self.paneSpacing) {
                    ForEach(0..<grid.columns, id: \.self) { column in
                        let index = row * grid.columns + column
                        if index < model.items.count {
                            paneView(index, viewport: pane)
                                .frame(width: pane.width, height: pane.height)
                        } else {
                            Color.clear.frame(width: pane.width, height: pane.height)
                        }
                    }
                }
            }
        }
    }

    private func paneView(_ index: Int, viewport: CGSize) -> some View {
        let item = model.items[index]
        let pane = model.pane(index, viewport: viewport)
        let layer = pane.map { pane in
            CompareSurfaceLayer(
                image: model.image(for: index),
                rect: model.state.imageRect(pane, reference: model.referenceSize, backingScale: model.backingScale),
                clip: nil,
                nearestNeighbour: model.state.usesNearestNeighbour(pane, reference: model.referenceSize, backingScale: model.backingScale)
            )
        }
        return ZStack {
            Color.appCanvasBackground
            CompareSurface(
                layers: layer.map { [$0] } ?? [],
                divider: nil,
                canPan: model.state.zoom != .fit
            ) { event in
                handle(event, pane: index, viewport: viewport)
            }
            if model.image(for: index) == nil {
                ProgressView().controlSize(.small)
            }
        }
        .overlay(alignment: .bottom) {
            CompareInfoBar(model: model, index: index, viewport: viewport, badge: nil)
                .padding(AppSpacing.md)
        }
        .clipped()
        .task(id: resolutionKey(index, viewport: viewport)) {
            model.ensureResolution(for: index, viewport: viewport)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name), \(model.zoomText(index, viewport: viewport))")
    }

    private func resolutionKey(_ index: Int, viewport: CGSize) -> String {
        let zoom = model.paneZoom(index, viewport: viewport) ?? 0
        return "\(model.items[index].path)|\(Int(viewport.width))x\(Int(viewport.height))|\(Int(zoom * 20))"
    }

    private func handle(_ event: CompareSurfaceEvent, pane index: Int, viewport: CGSize) {
        switch event {
        case let .zoom(factor, anchor):
            model.zoom(by: factor, anchor: anchor, pane: index, viewport: viewport)
        case let .pan(delta):
            model.pan(by: delta, pane: index, viewport: viewport)
        case let .doubleClick(point):
            withAnimation(.easeInOut(duration: 0.15)) {
                model.toggleFitActual(at: point, pane: index, viewport: viewport)
            }
        case let .divider(point):
            model.state.setWipePosition(CompareWipeGeometry.position(for: point, viewport: viewport, orientation: model.state.wipeOrientation))
        }
    }

    // MARK: Wipe

    private func wipe(size: CGSize) -> some View {
        let a = model.state.wipeA
        let b = model.state.wipeB
        let state = model.state
        var layers: [CompareSurfaceLayer] = []
        if let paneA = model.pane(a, viewport: size) {
            let aRect = state.imageRect(paneA, reference: model.referenceSize, backingScale: model.backingScale)
            let nearest = state.usesNearestNeighbour(paneA, reference: model.referenceSize, backingScale: model.backingScale)
            layers.append(CompareSurfaceLayer(image: model.image(for: a), rect: aRect, clip: nil, nearestNeighbour: nearest))
            if let bSize = model.items[b].pixelSize {
                let center = state.zoom == .fit ? CGPoint(x: 0.5, y: 0.5) : state.center
                let bRect = CompareWipeGeometry.bRect(aRect: aRect, bImage: bSize, center: center)
                let region = CompareWipeGeometry.bRegion(viewport: size, position: state.wipePosition, orientation: state.wipeOrientation)
                layers.append(CompareSurfaceLayer(image: model.image(for: b), rect: bRect, clip: region, nearestNeighbour: nearest))
            }
        }
        return ZStack {
            Color.appCanvasBackground
            CompareSurface(
                layers: layers,
                divider: (state.wipePosition, state.wipeOrientation),
                canPan: state.zoom != .fit
            ) { event in
                handle(event, pane: a, viewport: size)
            }
            if model.image(for: a) == nil || model.image(for: b) == nil {
                ProgressView().controlSize(.small)
            }
            CompareWipeDivider(position: state.wipePosition, orientation: state.wipeOrientation, size: size)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomLeading) {
            CompareInfoBar(model: model, index: a, viewport: size, badge: "A")
                .padding(AppSpacing.md)
        }
        .overlay(alignment: .bottomTrailing) {
            CompareInfoBar(model: model, index: b, viewport: size, badge: "B", widthMatchedTo: a)
                .padding(AppSpacing.md)
        }
        .clipped()
        .task(id: resolutionKey(a, viewport: size) + resolutionKey(b, viewport: size)) {
            model.ensureResolution(for: a, viewport: size)
            // B is drawn at A's width: ask for the pixels that needs.
            model.ensureResolution(for: b, viewport: wipeEquivalentViewport(b: b, a: a, size: size))
        }
    }

    /// A viewport in which B's pane zoom equals the zoom it's drawn at in the
    /// wipe (B spans A's width), for the decode-size calculation.
    private func wipeEquivalentViewport(b: Int, a: Int, size: CGSize) -> CGSize {
        guard let aSize = model.items[a].pixelSize, let bSize = model.items[b].pixelSize, aSize.width > 0 else { return size }
        let ratio = bSize.width / aSize.width
        return CGSize(width: size.width * ratio, height: size.height * ratio)
    }
}

// MARK: - Divider

private struct CompareWipeDivider: View {
    let position: CGFloat
    let orientation: CompareWipeOrientation
    let size: CGSize

    var body: some View {
        ZStack {
            switch orientation {
            case .vertical:
                Rectangle()
                    .fill(Color.appPrimaryText.opacity(0.85))
                    .frame(width: 2, height: size.height)
                    .position(x: size.width * position, y: size.height / 2)
                handle
                    .position(x: size.width * position, y: size.height / 2)
            case .horizontal:
                Rectangle()
                    .fill(Color.appPrimaryText.opacity(0.85))
                    .frame(width: size.width, height: 2)
                    .position(x: size.width / 2, y: size.height * position)
                handle
                    .position(x: size.width / 2, y: size.height * position)
            }
        }
        .shadow(color: Color.appShadowColor, radius: 4)
        .accessibilityHidden(true)
    }

    private var handle: some View {
        Image(systemName: orientation == .vertical ? "arrow.left.and.right" : "arrow.up.and.down")
            .font(.appIcon(11, weight: .semibold))
            .foregroundStyle(Color.appPrimaryText)
            .frame(width: 28, height: 28)
            .background(Circle().fill(Color.appOverlaySurface))
            .overlay(Circle().strokeBorder(Color.appOverlayStroke, lineWidth: 1))
    }
}

// MARK: - Info bar

/// Neutral facts for one image: name, pixel size, file size and its own zoom.
struct CompareInfoBar: View {
    @Environment(ExplorerViewModel.self) private var vm
    let model: CompareCanvasModel
    let index: Int
    let viewport: CGSize
    let badge: String?
    /// Wipe: B is drawn at A's width, so its zoom is derived from A's.
    var widthMatchedTo: Int?

    private var item: CompareItem { model.items[index] }

    private var zoomText: String {
        guard let reference = widthMatchedTo,
              let aZoom = model.paneZoom(reference, viewport: viewport),
              let aSize = model.items[reference].pixelSize, let bSize = item.pixelSize, bSize.width > 0
        else { return model.zoomText(index, viewport: viewport) }
        return "\(Int((aZoom * Double(aSize.width / bSize.width) * 100).rounded()))%"
    }

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            if let badge {
                Text(badge)
                    .font(.appCaptionEmphasis)
                    .foregroundStyle(Color.appPrimaryText)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.appElevatedSurface))
            }
            Text(item.name)
                .font(.appCaptionEmphasis)
                .foregroundStyle(Color.appPrimaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(details)
                .font(.appCaption)
                .foregroundStyle(Color.appMuted)
                .lineLimit(1)
                .monospacedDigit()
                .layoutPriority(1)
            Menu {
                ForEach(CompareImageAction.allCases) { action in
                    Button {
                        vm.performCompareAction(action, path: item.path)
                    } label: {
                        Label(action.title, systemImage: action.systemImage)
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Actions for \(item.name)")
            .accessibilityLabel("Actions for \(item.name)")
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.xs)
        .background(Capsule().fill(Color.appOverlaySurface))
        .overlay(Capsule().strokeBorder(Color.appOverlayStroke, lineWidth: 1))
        .frame(maxWidth: max(160, viewport.width - AppSpacing.md * 2), alignment: .center)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var details: String {
        var parts: [String] = []
        if let pixels = item.pixelText { parts.append(pixels) }
        if let size = item.fileSizeText { parts.append(size) }
        if item.isVideo { parts.append("Video frame") }
        parts.append(zoomText)
        return parts.joined(separator: " · ")
    }
}

// MARK: - Toolbar

/// Mode, zoom levels, framing and (for the wipe) orientation, A / B and swap.
struct CompareToolbar: View {
    @Bindable var model: CompareCanvasModel

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            Picker("Mode", selection: $model.state.mode) {
                ForEach(CompareMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Compare mode")

            divider

            HStack(spacing: AppSpacing.xxs) {
                ForEach(CompareZoomPreset.allCases) { preset in
                    let isCurrent = CompareZoomPreset.matching(model.state.zoom) == preset
                    Button(preset.title) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            model.applyPreset(preset, viewport: model.paneViewport)
                        }
                    }
                    .buttonStyle(AppLabeledButtonStyle(
                        height: 24,
                        horizontalPadding: AppSpacing.sm,
                        showsRestingChrome: isCurrent,
                        restingForeground: isCurrent ? Color.appPrimaryText : Color.appMuted
                    ))
                    .font(.appCaptionEmphasis)
                    .help(preset == .fit ? "Fit each image in its pane" : "Zoom to \(preset.title) (image A)")
                    .accessibilityAddTraits(isCurrent ? .isSelected : [])
                }
            }

            Text(model.zoomText(model.referenceIndex, viewport: model.paneViewport))
                .font(.appCaption)
                .foregroundStyle(Color.appMuted)
                .monospacedDigit()
                .frame(minWidth: 40, alignment: .leading)
                .help("Zoom of image A")

            divider

            Picker("Framing", selection: $model.state.framing) {
                ForEach(CompareFraming.allCases) { framing in
                    Text(framing.title).tag(framing)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help("Same Framing: every image shows the same part of the picture. Actual Pixels: 100 % is one image pixel per screen pixel for each.")
            .accessibilityLabel("Framing")

            if model.state.mode == .wipe {
                divider
                wipeControls
            }

            Spacer(minLength: 0)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.appBorder)
            .frame(width: 1, height: 18)
    }

    @ViewBuilder
    private var wipeControls: some View {
        Button {
            model.state.wipeOrientation = model.state.wipeOrientation == .vertical ? .horizontal : .vertical
        } label: {
            Image(systemName: model.state.wipeOrientation == .vertical ? "rectangle.split.2x1" : "rectangle.split.1x2")
                .font(.appIcon(12, weight: .medium))
        }
        .buttonStyle(AppIconButtonStyle(width: 26, height: 24))
        .help(model.state.wipeOrientation == .vertical ? "Horizontal divider (A on top)" : "Vertical divider (A on the left)")
        .accessibilityLabel("Divider orientation")
        .accessibilityValue(model.state.wipeOrientation.title)

        if model.items.count > 2 {
            wipePicker("A", selection: $model.state.wipeA)
            wipePicker("B", selection: $model.state.wipeB)
        }

        Button {
            model.state.swapWipe()
        } label: {
            Image(systemName: "arrow.left.arrow.right")
                .font(.appIcon(12, weight: .medium))
        }
        .buttonStyle(AppIconButtonStyle(width: 26, height: 24))
        .help("Swap A and B")
        .accessibilityLabel("Swap A and B")
    }

    private func wipePicker(_ title: String, selection: Binding<Int>) -> some View {
        Picker(title, selection: Binding(
            get: { selection.wrappedValue },
            set: { value in
                selection.wrappedValue = value
                if model.state.wipeA == model.state.wipeB {
                    // Picking the other side's file swaps the two.
                    if title == "A" { model.state.wipeB = model.items.indices.first { $0 != value } ?? 0 } else { model.state.wipeA = model.items.indices.first { $0 != value } ?? 0 }
                }
            }
        )) {
            ForEach(model.items.indices, id: \.self) { index in
                Text(model.items[index].name).tag(index)
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 180)
        .help("Image \(title) in the wipe")
    }
}
