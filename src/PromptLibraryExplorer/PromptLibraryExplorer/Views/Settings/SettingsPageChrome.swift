import SwiftUI

/// Title header plus scrolling body shared by every settings page, so a new
/// page only has to supply its cards.
struct SettingsPageScaffold<Content: View>: View {
    let page: SettingsPage
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Text(page.title)
                    .font(.appIcon(22, weight: .bold))
                    .foregroundStyle(Color.appPrimaryText)

                Text(page.summary)
                    .font(.appBody)
                    .foregroundStyle(Color.appMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AppSpacing.xxl)
            .padding(.top, 22)
            .padding(.bottom, 18)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.appBorder)
                    .frame(height: 1)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    content
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding(AppSpacing.xxl)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.appBackground)
    }
}

/// The rounded surface every settings block sits on.
struct SettingsCard<Content: View>: View {
    var title: String?
    var icon: String?
    var cornerRadius: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            if let title, let icon {
                Label(title, systemImage: icon)
                    .font(.appHeadline)
                    .foregroundStyle(Color.appAccent)
            } else if let title {
                Text(title)
                    .font(.appHeadline)
                    .foregroundStyle(Color.appAccent)
            }

            content
        }
        .padding(AppSpacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color.appSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(Color.appBorder, lineWidth: 1)
        )
    }
}

/// Label / qualifier / value row, for read-only figures like cache usage.
struct SettingsStatRow: View {
    let label: String
    let detail: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.appIcon(14, weight: .medium))
                .foregroundStyle(Color.appPrimaryText)

            Text(detail)
                .font(.appCallout)
                .foregroundStyle(Color.appMuted)

            Spacer(minLength: 8)

            Text(value)
                .font(.appTitle.monospacedDigit())
                .foregroundStyle(Color.appPrimaryText)
        }
    }
}

/// Checkbox plus optional sub-line, for a single boolean preference.
///
/// The checkbox is drawn rather than using `.toggleStyle(.checkbox)`, because
/// AppKit fills a native checkbox with the *system* control accent and ignores
/// `.tint` — which would put stock blue in the middle of a branded page.
struct SettingsToggleRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Button {
                isOn.toggle()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: AppSpacing.md) {
                    Image(systemName: isOn ? "checkmark.square.fill" : "square")
                        .font(.appBody)
                        .foregroundStyle(isOn ? Color.appAccent : Color.appMuted)

                    Text(title)
                        .font(.appIcon(13, weight: .medium))
                        .foregroundStyle(Color.appPrimaryText)

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let detail {
                Text(detail)
                    .font(.appCallout)
                    .foregroundStyle(Color.appMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 21)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A vertical list of mutually exclusive options, each with its own explanation.
/// Radio buttons rather than a popup so the trade-offs stay visible.
struct SettingsChoiceRow<Option: Identifiable & Equatable>: View {
    let options: [Option]
    let title: (Option) -> String
    let explanation: (Option) -> String
    @Binding var selection: Option

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(options) { option in
                Button {
                    selection = option
                } label: {
                    HStack(alignment: .top, spacing: AppSpacing.md) {
                        Image(systemName: option == selection ? "largecircle.fill.circle" : "circle")
                            .font(.appBody)
                            .foregroundStyle(option == selection ? Color.appAccent : Color.appMuted)

                        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                            Text(title(option))
                                .font(.appIcon(13, weight: .medium))
                                .foregroundStyle(Color.appPrimaryText)

                            Text(explanation(option))
                                .font(.appCallout)
                                .foregroundStyle(Color.appMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Explanatory copy in the muted body style used throughout the pages.
struct SettingsFootnote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.appBody)
            .foregroundStyle(Color.appMuted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Filled action button used for the destructive and primary settings actions.
/// Thin wrapper over `AppPrimaryButtonStyle` so settings share the app-wide
/// primary treatment (including the readable disabled state).
struct SettingsFilledButton: View {
    let title: String
    var tint: Color = .appAccent
    var isBusy = false
    var isEnabled = true
    let action: () async -> Void

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: AppSpacing.md) {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.appPrimaryText)
                }
                Text(title)
            }
        }
        .buttonStyle(
            AppPrimaryButtonStyle(
                tint: tint,
                font: .appTitle,
                horizontalPadding: AppSpacing.xl,
                verticalPadding: 10,
                cornerRadius: AppRadius.lg
            )
        )
        .disabled(!isEnabled || isBusy)
    }
}

/// Icon + heading + description + action, for a page's headline operations.
struct SettingsActionCard<Extra: View>: View {
    let title: String
    let description: String
    let icon: String
    let accent: Color
    let buttonTitle: String
    var isBusy = false
    var isEnabled = true
    let action: () async -> Void
    @ViewBuilder var extraContent: Extra

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xl) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: AppRadius.lg)
                        .fill(accent.opacity(0.14))
                    Image(systemName: icon)
                        .font(.appLargeTitle)
                        .foregroundStyle(accent)
                }
                .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    Text(title)
                        .font(.appIcon(17, weight: .semibold))
                        .foregroundStyle(Color.appPrimaryText)

                    Text(description)
                        .font(.appIcon(14))
                        .foregroundStyle(Color.appMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            extraContent

            HStack(spacing: AppSpacing.lg) {
                SettingsFilledButton(
                    title: buttonTitle,
                    tint: accent,
                    isBusy: isBusy,
                    isEnabled: isEnabled,
                    action: action
                )

                if isBusy {
                    Text("Processing…")
                        .font(.appIcon(13, weight: .medium))
                        .foregroundStyle(Color.appMuted)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xxl)
                .fill(Color.appSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xxl)
                .strokeBorder(Color.appBorder, lineWidth: 1)
        )
    }
}

extension SettingsActionCard where Extra == EmptyView {
    init(
        title: String,
        description: String,
        icon: String,
        accent: Color,
        buttonTitle: String,
        isBusy: Bool = false,
        isEnabled: Bool = true,
        action: @escaping () async -> Void
    ) {
        self.init(
            title: title,
            description: description,
            icon: icon,
            accent: accent,
            buttonTitle: buttonTitle,
            isBusy: isBusy,
            isEnabled: isEnabled,
            action: action,
            extraContent: { EmptyView() }
        )
    }
}

/// Inline outcome message for an action that just ran on this page.
struct SettingsResultBanner: View {
    let message: String
    let tone: ToastType

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.lg) {
            Image(systemName: icon)
                .font(.appIcon(15, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 18)

            Text(message)
                .font(.appIcon(14, weight: .medium))
                .foregroundStyle(Color.appPrimaryText)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(AppSpacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .fill(color.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .strokeBorder(color.opacity(0.35), lineWidth: 1)
        )
    }

    private var color: Color {
        switch tone {
        case .success: return Color.appSuccess
        case .error: return Color.appError
        case .info: return Color.appAccent
        }
    }

    private var icon: String {
        switch tone {
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }
}
