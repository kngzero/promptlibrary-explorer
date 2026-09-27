import AppKit
import SwiftUI

// Colour search UI: the Filter ▸ Colour… popover, swatches, the details-panel
// dominant-colour card and the optional grid-tile colour strip.

// MARK: - Palette editing

/// 1–3 colours (preset swatches, a hex value or the system colour panel)
/// plus a tolerance. Shared by the colour filter popover and the smart-folder
/// dominant-colour rule. `onCommit` runs after every change to the colours and
/// when a tolerance drag ends.
struct PaletteFieldsEditor: View {
    @Binding var colors: [String]
    @Binding var tolerance: Double
    var onCommit: () -> Void = {}

    @State private var hexDraft = ""

    static let presets: [String] = [
        "#E53935", "#FB8C00", "#FDD835", "#7CB342", "#2E7D32", "#00897B",
        "#00ACC1", "#1E88E5", "#3949AB", "#8E24AA", "#D81B60", "#F48FB1",
        "#6D4C41", "#D7CCC8", "#9E9E9E", "#212121", "#FAFAFA", "#FFE0B2",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            // Chosen colours
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Text(colors.isEmpty ? "Pick up to \(ColorFilter.maxColors) colours" : "Colours")
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
                HStack(spacing: AppSpacing.sm) {
                    ForEach(Array(colors.enumerated()), id: \.offset) { index, hex in
                        chosenColor(index: index, hex: hex)
                    }
                    if colors.isEmpty {
                        Text("None")
                            .font(.appCallout)
                            .foregroundStyle(Color.appMuted)
                    }
                    Spacer(minLength: 0)
                }
            }

            // Presets
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(22), spacing: AppSpacing.xs), count: 9),
                alignment: .leading,
                spacing: AppSpacing.xs
            ) {
                ForEach(Self.presets, id: \.self) { hex in
                    Button {
                        add(hex)
                    } label: {
                        ColorSwatch(hex: hex, size: 22)
                    }
                    .buttonStyle(.plain)
                    .disabled(colors.count >= ColorFilter.maxColors)
                    .help("Add \(hex)")
                    .accessibilityLabel("Add colour \(hex)")
                }
            }

            // Hex field + system colour panel
            HStack(spacing: AppSpacing.sm) {
                TextField("#RRGGBB", text: $hexDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.appMono)
                    .frame(width: 100)
                    .onSubmit(addDraft)
                Button("Add", action: addDraft)
                    .disabled(PaletteColor.normalizedHex(hexDraft) == nil || colors.count >= ColorFilter.maxColors)
                ColorPicker(
                    "Other…",
                    selection: Binding(
                        get: { Color(hex: colors.last ?? "#808080") },
                        set: { newValue in
                            guard let hex = PaletteColor(nsColor: NSColor(newValue))?.hex else { return }
                            if colors.isEmpty {
                                add(hex)
                            } else if colors[colors.count - 1] != hex {
                                colors[colors.count - 1] = hex
                                onCommit()
                            }
                        }
                    ),
                    supportsOpacity: false
                )
                .font(.appCallout)
                .help("Change the last colour with the system colour panel")
            }

            // Tolerance
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                HStack {
                    Text("Tolerance")
                        .font(.appCaption)
                        .foregroundStyle(Color.appMuted)
                    Spacer()
                    Text("\(Int((tolerance * 100).rounded()))%")
                        .font(.appMono)
                        .foregroundStyle(Color.appPrimaryText)
                        .monospacedDigit()
                }
                Slider(value: $tolerance, in: 0...1) {
                    Text("Tolerance")
                } minimumValueLabel: {
                    Text("Exact").font(.appFootnote).foregroundStyle(Color.appMuted)
                } maximumValueLabel: {
                    Text("Loose").font(.appFootnote).foregroundStyle(Color.appMuted)
                } onEditingChanged: { editing in
                    if !editing { onCommit() }
                }
                .tint(Color.appAccent)
                .accessibilityLabel("Colour tolerance")
            }
        }
    }

    private func chosenColor(index: Int, hex: String) -> some View {
        ZStack(alignment: .topTrailing) {
            ColorSwatch(hex: hex, size: 34)
                .help(hex)
            Button {
                colors.remove(at: index)
                onCommit()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.appIcon(11))
                    .foregroundStyle(Color.appPrimaryText, Color.appElevatedSurface)
            }
            .buttonStyle(.plain)
            .offset(x: 5, y: -5)
            .help("Take \(hex) out of the palette")
            .accessibilityLabel("Take colour \(hex) out of the palette")
        }
    }

    private func add(_ hex: String) {
        guard let normalized = PaletteColor.normalizedHex(hex),
              colors.count < ColorFilter.maxColors,
              !colors.contains(normalized)
        else { return }
        colors.append(normalized)
        onCommit()
    }

    private func addDraft() {
        guard PaletteColor.normalizedHex(hexDraft) != nil else { return }
        add(hexDraft)
        hexDraft = ""
    }
}

// MARK: - Colour filter popover

/// Filter ▸ Colour…: edits the listing's colour filter live.
struct ColorFilterEditor: View {
    @Environment(ExplorerViewModel.self) private var vm
    var onClose: () -> Void = {}

    @State private var colors: [String] = []
    @State private var tolerance: Double = ColorFilter.defaultTolerance
    @State private var didLoad = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            HStack {
                Image(systemName: "paintpalette")
                    .foregroundStyle(Color.appAccent)
                Text("Filter by Colour")
                    .font(.appHeadline)
                    .foregroundStyle(Color.appPrimaryText)
                Spacer()
            }

            PaletteFieldsEditor(colors: $colors, tolerance: $tolerance, onCommit: apply)

            Divider()

            HStack(spacing: AppSpacing.sm) {
                Button("Clear") {
                    colors = []
                    vm.setColorFilter(nil)
                }
                .disabled(vm.filterConfig.colorFilter == nil && colors.isEmpty)

                Spacer()

                Button {
                    let palette = colors
                    onClose()
                    vm.findImagesMatchingPalette(palette)
                } label: {
                    Label("Find Matching", systemImage: "sparkle.magnifyingglass")
                }
                .disabled(colors.isEmpty)
                .help("Rank images \(vm.visualScopeDescription) by how well they match these colours")

                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AppSpacing.xl)
        .frame(width: 300)
        .onAppear(perform: load)
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        if let filter = vm.filterConfig.colorFilter {
            colors = filter.palette
            tolerance = filter.tolerance
        } else {
            tolerance = vm.rememberedColorTolerance
        }
    }

    private func apply() {
        vm.rememberedColorTolerance = tolerance
        vm.setColorFilter(ColorFilter(palette: colors, tolerance: tolerance))
    }
}

// MARK: - Swatches

struct ColorSwatch: View {
    let hex: String
    var size: CGFloat = 20
    var cornerRadius: CGFloat = AppRadius.sm

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color(hex: hex))
            .frame(width: size, height: size)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.appControlBorder, lineWidth: 1)
            )
    }
}

/// Status-bar chip for an active colour filter: swatches (click to edit) + clear.
struct ColorFilterChip: View {
    @Environment(ExplorerViewModel.self) private var vm
    let filter: ColorFilter
    @State private var isEditing = false

    var body: some View {
        HStack(spacing: AppSpacing.xs) {
            Button {
                isEditing = true
            } label: {
                HStack(spacing: 2) {
                    ForEach(filter.palette, id: \.self) { hex in
                        ColorSwatch(hex: hex, size: 10, cornerRadius: 2)
                    }
                }
            }
            .buttonStyle(.plain)
            .help("Colour filter: \(filter.summary) — click to edit")
            .popover(isPresented: $isEditing, arrowEdge: .top) {
                ColorFilterEditor { isEditing = false }
                    .environment(vm)
            }

            Button {
                vm.setColorFilter(nil)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.appIcon(9))
            }
            .buttonStyle(AppIconButtonStyle(width: 16, height: 16, cornerRadius: AppRadius.md, showsRestingChrome: false))
            .help("Clear Colour Filter")
            .accessibilityLabel("Clear colour filter")
        }
    }
}

// MARK: - Grid tile strip

/// Thin bar of a file's dominant colours, each as wide as its share.
struct DominantColorBar: View {
    let colors: [DominantColor]
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geometry in
            let total = max(colors.reduce(0) { $0 + max($1.weight, 0) }, 0.0001)
            HStack(spacing: 0) {
                ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                    Rectangle()
                        .fill(Color(hex: color.hex))
                        .frame(width: geometry.size.width * CGFloat(max(color.weight, 0) / total))
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - Details panel

/// Dominant colours of one file from the visual index: click a swatch to
/// filter the listing by it; buttons for palette search and More Like This.
struct DominantColorsSection: View {
    @Environment(ExplorerViewModel.self) private var vm
    let path: String

    private var item: FileEntry? {
        vm.listingSourceContents.first(where: { $0.path == path })
    }

    @State private var colors: [DominantColor] = []
    @State private var didLoad = false

    private var indexController: VisualIndexController { VisualIndexController.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            if colors.isEmpty {
                Text(didLoad ? notIndexedText : "Loading colours…")
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
            } else {
                HStack(spacing: AppSpacing.sm) {
                    ForEach(colors, id: \.self) { color in
                        Button {
                            vm.filterByColor(color.hex)
                        } label: {
                            VStack(spacing: AppSpacing.xxs) {
                                ColorSwatch(hex: color.hex, size: 26)
                                Text("\(Int((color.weight * 100).rounded()))%")
                                    .font(.appFootnote)
                                    .foregroundStyle(Color.appMuted)
                                    .monospacedDigit()
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Filter this listing by \(color.hex)")
                        .accessibilityLabel("Filter by colour \(color.hex)")
                    }
                    Spacer(minLength: 0)
                }
                DominantColorBar(colors: colors, height: 5)
                    .clipShape(Capsule())
            }

            HStack(spacing: AppSpacing.sm) {
                Button {
                    if let item { vm.showMoreLikeThis(for: item) }
                } label: {
                    Label("More Like This", systemImage: "sparkle.magnifyingglass")
                        .font(.appCaption)
                }
                .buttonStyle(AppLabeledButtonStyle(height: 24, horizontalPadding: AppSpacing.md))
                .disabled(item == nil)
                .help("Show visually similar files \(vm.visualScopeDescription) (M)")

                Button {
                    if let item { vm.findImagesMatchingPalette(of: item) }
                } label: {
                    Label("Matching Colours", systemImage: "paintpalette")
                        .font(.appCaption)
                }
                .buttonStyle(AppLabeledButtonStyle(height: 24, horizontalPadding: AppSpacing.md))
                .disabled(colors.isEmpty || item == nil)
                .help("Find images whose colours match this file's \(vm.visualScopeDescription)")
            }
        }
        .task(id: "\(path)|\(indexController.lastCompleted?.timeIntervalSinceReferenceDate ?? 0)") {
            let target = path
            let loaded = await VisualIndexService.shared.dominantColors(forPaths: [target])[target] ?? []
            guard !Task.isCancelled else { return }
            colors = loaded
            didLoad = true
        }
    }

    private var notIndexedText: String {
        switch indexController.state {
        case .indexing: return "Not indexed yet — indexing is running."
        case .paused, .stopped: return "Not indexed yet. Resume indexing in Settings ▸ Search Index."
        default: return "No colour data for this file yet."
        }
    }
}
