import SwiftUI

/// Shared control chrome for app buttons. Every control built on these styles
/// responds to the four interaction states:
///
/// - inactive: disabled, dimmed, and unreactive to the pointer
/// - active: enabled and at rest
/// - hover: pointer is over the control
/// - pressed: the control is being clicked
///
/// The chrome is drawn behind the label and the full frame is hit-testable, so
/// clicks land anywhere in the control instead of only on the icon glyph.
private struct ControlSurface<Label: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    let label: Label
    let isPressed: Bool
    let width: CGFloat?
    let height: CGFloat
    let horizontalPadding: CGFloat
    let cornerRadius: CGFloat
    /// When false the control is transparent at rest and only grows chrome on hover/press.
    let showsRestingChrome: Bool
    /// Overrides the resting label color, e.g. to emphasize the current breadcrumb.
    let restingForeground: Color?

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    private var foreground: Color {
        guard isEnabled else { return (restingForeground ?? .appMuted).opacity(0.4) }
        if isPressed { return .appAccentHover }
        if isHovering { return .appPrimaryText }
        return restingForeground ?? .appMuted
    }

    private var background: Color {
        guard isEnabled else { return showsRestingChrome ? .appSurface.opacity(0.5) : .clear }
        if isPressed { return .appSelected }
        if isHovering { return .appHover }
        return showsRestingChrome ? .appSurface : .clear
    }

    private var border: Color {
        // Controls without resting chrome stay borderless in every state. A
        // border that only exists while hovered or pressed pops in and out
        // around the glyph, which reads as the control shifting.
        guard showsRestingChrome else { return .clear }
        guard isEnabled else { return .appBorder.opacity(0.5) }
        if isPressed { return .appAccent.opacity(0.55) }
        if isHovering { return .appControlBorder }
        return .appBorder
    }

    var body: some View {
        // The chrome is a sibling of the label, not a `.background` modifier on
        // it. As a modifier the chrome lives inside the label's own layer, so a
        // press landing on the glyph moves the chrome with it; as a sibling its
        // geometry comes from the ZStack frame and cannot follow the label.
        // Only hover animates — a press-time animation would carry any
        // coincident change into a visible slide.
        ZStack {
            shape
                .fill(background)
                .overlay(shape.strokeBorder(border, lineWidth: 1))
                .animation(.easeOut(duration: 0.12), value: isHovering)

            label
                .foregroundStyle(foreground)
                .padding(.horizontal, horizontalPadding)
        }
        .frame(width: width, height: height)
        .contentShape(shape)
        .onHover { hovering in
            isHovering = hovering && isEnabled
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { isHovering = false }
        }
    }
}

/// Square icon button with resting chrome — toolbar-style controls.
struct AppIconButtonStyle: ButtonStyle {
    var width: CGFloat = 28
    var height: CGFloat = 28
    var cornerRadius: CGFloat = AppRadius.md
    var showsRestingChrome: Bool = true
    var restingForeground: Color?

    func makeBody(configuration: Configuration) -> some View {
        ControlSurface(
            label: configuration.label,
            isPressed: configuration.isPressed,
            width: width,
            height: height,
            horizontalPadding: 0,
            cornerRadius: cornerRadius,
            showsRestingChrome: showsRestingChrome,
            restingForeground: restingForeground
        )
    }
}

/// Icon button for segments that already sit inside a pill or panel, so the
/// control stays transparent until hovered or clicked.
struct AppSegmentButtonStyle: ButtonStyle {
    var width: CGFloat = 28
    var height: CGFloat = 26
    var restingForeground: Color?

    func makeBody(configuration: Configuration) -> some View {
        ControlSurface(
            label: configuration.label,
            isPressed: configuration.isPressed,
            width: width,
            height: height,
            horizontalPadding: 0,
            cornerRadius: height / 2,
            showsRestingChrome: false,
            restingForeground: restingForeground
        )
    }
}

/// Adds the four interaction states to a button that already draws its own
/// chrome (lightbox overlays, accent call-to-action buttons, tag chips), and
/// makes that whole chrome clickable rather than just the glyph.
struct AppAdaptiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AdaptiveSurface(label: configuration.label, isPressed: configuration.isPressed)
    }

    private struct AdaptiveSurface<Label: View>: View {
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        let label: Label
        let isPressed: Bool

        // Brightness and opacity ride on the label itself, so these states switch
        // instantly rather than through an animation that could also carry a
        // coincident layout change.
        var body: some View {
            label
                .contentShape(Rectangle())
                .brightness(isEnabled && isHovering && !isPressed ? 0.08 : 0)
                .opacity(isEnabled ? (isPressed ? 0.75 : 1) : 0.4)
                .onHover { hovering in
                    isHovering = hovering && isEnabled
                }
                .onChange(of: isEnabled) { _, enabled in
                    if !enabled { isHovering = false }
                }
        }
    }
}

/// Text or icon-and-text button with resting chrome.
struct AppLabeledButtonStyle: ButtonStyle {
    var height: CGFloat = 28
    var horizontalPadding: CGFloat = 10
    var cornerRadius: CGFloat = AppRadius.md
    var showsRestingChrome: Bool = true
    var restingForeground: Color?

    func makeBody(configuration: Configuration) -> some View {
        ControlSurface(
            label: configuration.label,
            isPressed: configuration.isPressed,
            width: nil,
            height: height,
            horizontalPadding: horizontalPadding,
            cornerRadius: cornerRadius,
            showsRestingChrome: showsRestingChrome,
            restingForeground: restingForeground
        )
    }
}

/// Filled call-to-action button: the one primary action in a sheet, popover or
/// settings card. Replaces `.borderedProminent` + `.tint(.appAccent)` so every
/// primary action shares one shape, weight and disabled treatment.
///
/// Disabled state swaps the fill for `appElevatedSurface` and the label for
/// `appDisabledText`, which stays readable in both modes (white on the light
/// elevated surface was ~1.4:1).
struct AppPrimaryButtonStyle: ButtonStyle {
    var tint: Color = .appAccent
    var foreground: Color = .white
    var font: Font? = nil
    var horizontalPadding: CGFloat = AppSpacing.lg
    var verticalPadding: CGFloat = AppSpacing.sm
    var cornerRadius: CGFloat = AppRadius.md
    var minWidth: CGFloat? = nil

    func makeBody(configuration: Configuration) -> some View {
        PrimarySurface(
            label: configuration.label,
            isPressed: configuration.isPressed,
            style: self
        )
    }

    private struct PrimarySurface<Label: View>: View {
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        let label: Label
        let isPressed: Bool
        let style: AppPrimaryButtonStyle

        private var shape: RoundedRectangle {
            RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
        }

        var body: some View {
            label
                .font(style.font)
                .foregroundStyle(isEnabled ? style.foreground : Color.appDisabledText)
                .frame(minWidth: style.minWidth)
                .padding(.horizontal, style.horizontalPadding)
                .padding(.vertical, style.verticalPadding)
                .background(shape.fill(isEnabled ? style.tint : Color.appElevatedSurface))
                .overlay(shape.strokeBorder(isEnabled ? Color.clear : Color.appBorder, lineWidth: 1))
                .contentShape(shape)
                .brightness(isEnabled && isHovering && !isPressed ? 0.06 : 0)
                .opacity(isPressed ? 0.8 : 1)
                .onHover { hovering in
                    isHovering = hovering && isEnabled
                }
                .onChange(of: isEnabled) { _, enabled in
                    if !enabled { isHovering = false }
                }
        }
    }
}
