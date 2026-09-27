import SwiftUI

// Grid / list decorations for version stacks. A stack head (the tile standing for a
// stack) gets subtle stacked edges behind the thumbnail and a count badge whose chevron
// expands / collapses the stack inline. Members shown because their stack is expanded
// get a thin accent rail so the group reads as one.

/// Two offset cards peeking out behind a collapsed stack's thumbnail.
struct StackTileEdges: View {
    @Environment(ExplorerViewModel.self) private var vm
    let path: String
    let size: CGFloat

    var body: some View {
        if let head = vm.stackHead(for: path), !head.isExpanded {
            ZStack {
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    .fill(Color.appElevatedSurface.opacity(0.55))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                            .strokeBorder(Color.appBorder, lineWidth: 1)
                    )
                    .frame(width: size, height: size)
                    .offset(x: 6, y: -6)
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    .fill(Color.appElevatedSurface.opacity(0.85))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                            .strokeBorder(Color.appBorder, lineWidth: 1)
                    )
                    .frame(width: size, height: size)
                    .offset(x: 3, y: -3)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// Count badge + expand / collapse chevron at the thumbnail's bottom centre (use in a
/// `.top`-aligned overlay of the tile). Sits above the tile's click / drag layer so the
/// chevron is clickable.
struct StackTileBadge: View {
    @Environment(ExplorerViewModel.self) private var vm
    let path: String
    let size: CGFloat
    let cellWidth: CGFloat

    var body: some View {
        if let head = vm.stackHead(for: path) {
            Button {
                vm.toggleStackExpansion(head.stackID)
            } label: {
                HStack(spacing: AppSpacing.xxs) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.appIcon(9, weight: .semibold))
                    Text("\(head.visibleCount)")
                        .font(.appMicro)
                        .monospacedDigit()
                    Image(systemName: head.isExpanded ? "chevron.left" : "chevron.right")
                        .font(.appIcon(8, weight: .bold))
                }
                .foregroundStyle(Color.white)
                .padding(.horizontal, AppSpacing.sm)
                .padding(.vertical, AppSpacing.xxs + 1)
                .background(
                    Capsule(style: .continuous)
                        .fill(head.isExpanded ? Color.appAccent : Color.black.opacity(0.62))
                )
                .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
            }
            .buttonStyle(AppAdaptiveButtonStyle())
            .help(head.isExpanded ? "Collapse stack" : "Expand stack (\(head.visibleCount) variants)")
            .accessibilityLabel(head.isExpanded ? "Collapse stack of \(head.visibleCount)" : "Expand stack of \(head.visibleCount)")
            // Bottom centre of the thumbnail (the corners hold the type, cloud and cull badges).
            .offset(y: size - 30)
        }
    }
}

/// Accent rail on the leading edge of members listed because their stack is expanded.
struct StackMemberRail: View {
    @Environment(ExplorerViewModel.self) private var vm
    let path: String
    let size: CGFloat

    var body: some View {
        if vm.isExpandedStackMember(path) {
            Capsule(style: .continuous)
                .fill(Color.appAccent.opacity(0.7))
                .frame(width: 3, height: size * 0.6)
                .offset(x: -5)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// List-row badge: stack count with an expand / collapse chevron, or a member marker.
struct StackListBadge: View {
    @Environment(ExplorerViewModel.self) private var vm
    let path: String

    var body: some View {
        if let head = vm.stackHead(for: path) {
            Button {
                vm.toggleStackExpansion(head.stackID)
            } label: {
                HStack(spacing: AppSpacing.xxs) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.appIcon(9, weight: .semibold))
                    Text("\(head.visibleCount)")
                        .font(.appMicro)
                        .monospacedDigit()
                    Image(systemName: head.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.appIcon(8, weight: .bold))
                }
                .foregroundStyle(head.isExpanded ? Color.appAccent : Color.appMuted)
                .padding(.horizontal, AppSpacing.xs)
                .padding(.vertical, 1)
                .background(Capsule(style: .continuous).fill(Color.appElevatedSurface.opacity(0.8)))
            }
            .buttonStyle(AppAdaptiveButtonStyle())
            .help(head.isExpanded ? "Collapse stack" : "Expand stack (\(head.visibleCount) variants)")
            .accessibilityLabel(head.isExpanded ? "Collapse stack of \(head.visibleCount)" : "Expand stack of \(head.visibleCount)")
        } else if vm.isExpandedStackMember(path) {
            Image(systemName: "arrow.turn.down.right")
                .font(.appIcon(9, weight: .semibold))
                .foregroundStyle(Color.appAccent.opacity(0.8))
                .help("In an expanded stack")
                .accessibilityLabel("In an expanded stack")
        }
    }
}
