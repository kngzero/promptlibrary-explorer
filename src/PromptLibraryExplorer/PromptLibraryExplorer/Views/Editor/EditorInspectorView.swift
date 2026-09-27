import SwiftUI

/// The editor's right-hand panel: the current tool's controls.
struct EditorInspectorView: View {
    @Bindable var session: EditorSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.xl) {
                switch session.tool {
                case .crop: cropControls
                case .adjust: adjustControls
                }
                Divider().background(Color.appBorder)
                Text(session.recipe.summary)
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Edits are saved with your curation data (like ratings), not in the file. Exports and Send to Mood / Story use the edited version.")
                    .font(.appFootnote)
                    .foregroundStyle(Color.appMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(AppSpacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(session.isLoading || session.loadError != nil)
    }

    // MARK: Crop & Rotate

    @ViewBuilder
    private var cropControls: some View {
        section("Aspect Ratio") {
            Picker("Aspect Ratio", selection: Binding(
                get: { session.recipe.aspect },
                set: { session.setAspect($0) }
            )) {
                ForEach(EditAspect.allCases) { aspect in
                    Text(aspect.title).tag(aspect)
                }
            }
            .labelsHidden()
            .accessibilityLabel("Aspect ratio")
            Button {
                session.resetCrop()
            } label: {
                Label("Reset Crop", systemImage: "crop")
                    .font(.appCaption)
            }
            .buttonStyle(AppLabeledButtonStyle(height: 26, horizontalPadding: AppSpacing.md))
            .help("The largest crop of this ratio")
        }

        section("Straighten") {
            HStack(spacing: AppSpacing.sm) {
                Slider(
                    value: Binding(
                        get: { session.recipe.straighten },
                        set: { session.setStraighten($0) }
                    ),
                    in: EditRecipe.straightenRange,
                    onEditingChanged: { editing in
                        if editing { session.beginInteraction() } else { session.endInteraction() }
                    }
                )
                .accessibilityLabel("Straighten")
                .accessibilityValue(String(format: "%.1f degrees", session.recipe.straighten))
                Text(String(format: "%+.1f°", session.recipe.straighten))
                    .font(.appMono)
                    .foregroundStyle(Color.appPrimaryText)
                    .frame(width: 52, alignment: .trailing)
                resetButton(disabled: session.recipe.straighten == 0, label: "Reset straighten") {
                    session.setStraightenDiscrete(0)
                }
            }
            Text("The crop shrinks so no empty corners show. A finer grid appears while you drag.")
                .font(.appFootnote)
                .foregroundStyle(Color.appMuted)
                .fixedSize(horizontal: false, vertical: true)
        }

        section("Rotate & Flip") {
            HStack(spacing: AppSpacing.sm) {
                iconButton("rotate.left", help: "Rotate 90° Left", label: "Rotate left") { session.rotate(clockwise: false) }
                iconButton("rotate.right", help: "Rotate 90° Right", label: "Rotate right") { session.rotate(clockwise: true) }
                Divider().frame(height: 20)
                iconButton("arrow.left.and.right.righttriangle.left.righttriangle.right", help: "Flip Horizontal", label: "Flip horizontal", active: session.recipe.flipHorizontal) {
                    session.flip(horizontal: true)
                }
                iconButton("arrow.up.and.down.righttriangle.up.righttriangle.down", help: "Flip Vertical", label: "Flip vertical", active: session.recipe.flipVertical) {
                    session.flip(horizontal: false)
                }
            }
            Button {
                session.resetGeometry()
            } label: {
                Label("Reset Crop & Rotation", systemImage: "arrow.counterclockwise")
                    .font(.appCaption)
            }
            .buttonStyle(AppLabeledButtonStyle(height: 26, horizontalPadding: AppSpacing.md))
            .disabled(!session.recipe.hasGeometry)
        }
    }

    // MARK: Adjust

    @ViewBuilder
    private var adjustControls: some View {
        section("Light & Colour") {
            adjustSlider("Exposure", value: \.exposure, range: EditRecipe.exposureRange, format: "%+.2f EV")
            adjustSlider("Contrast", value: \.contrast, range: EditRecipe.unitRange, format: "%+.2f")
            adjustSlider("Saturation", value: \.saturation, range: EditRecipe.unitRange, format: "%+.2f")
            adjustSlider("Temperature", value: \.temperature, range: EditRecipe.unitRange, format: "%+.2f")
        }
        Button {
            session.resetAdjustments()
        } label: {
            Label("Reset Adjustments", systemImage: "arrow.counterclockwise")
                .font(.appCaption)
        }
        .buttonStyle(AppLabeledButtonStyle(height: 26, horizontalPadding: AppSpacing.md))
        .disabled(!session.recipe.hasAdjustments)
    }

    private func adjustSlider(_ title: String, value keyPath: WritableKeyPath<EditRecipe, Double>, range: ClosedRange<Double>, format: String) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
            HStack {
                Text(title)
                    .font(.appCallout)
                    .foregroundStyle(Color.appPrimaryText)
                Spacer()
                Text(String(format: format, session.recipe[keyPath: keyPath]))
                    .font(.appMono)
                    .foregroundStyle(Color.appMuted)
                resetButton(disabled: session.recipe[keyPath: keyPath] == 0, label: "Reset \(title.lowercased())") {
                    session.change { $0[keyPath: keyPath] = 0 }
                }
            }
            Slider(
                value: Binding(
                    get: { session.recipe[keyPath: keyPath] },
                    set: { newValue in session.interactiveChange { $0[keyPath: keyPath] = newValue } }
                ),
                in: range,
                onEditingChanged: { editing in
                    if editing { session.beginInteraction() } else { session.endInteraction() }
                }
            )
            .accessibilityLabel(title)
            .accessibilityValue(String(format: format, session.recipe[keyPath: keyPath]))
        }
    }

    // MARK: Pieces

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text(title.uppercased())
                .font(.appIcon(10, weight: .semibold)).tracking(0.8)
                .foregroundStyle(Color.appMuted)
            content()
        }
    }

    private func iconButton(_ systemName: String, help: String, label: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.appIcon(14, weight: .medium))
        }
        .buttonStyle(AppIconButtonStyle(width: 32, height: 30, restingForeground: active ? Color.appAccent : nil))
        .help(help)
        .accessibilityLabel(label)
        .accessibilityValue(active ? "On" : "")
    }

    private func resetButton(disabled: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.counterclockwise")
                .font(.appCaption)
        }
        .buttonStyle(AppIconButtonStyle(width: 22, height: 22, cornerRadius: AppRadius.sm, showsRestingChrome: false))
        .disabled(disabled)
        .help("Reset")
        .accessibilityLabel(label)
    }
}
