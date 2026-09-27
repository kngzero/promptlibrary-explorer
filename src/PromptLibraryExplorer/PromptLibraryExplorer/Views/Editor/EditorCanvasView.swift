import SwiftUI

/// The editor's image: the full straightened, turned frame with the crop drawn over it
/// (Crop & Rotate), or the finished edit (Adjust). Holding Compare shows the original.
struct EditorCanvasView: View {
    @Bindable var session: EditorSession
    private let padding: CGFloat = 28

    var body: some View {
        GeometryReader { geometry in
            let area = CGRect(origin: .zero, size: geometry.size).insetBy(dx: padding, dy: padding)
            ZStack {
                Color.appCanvasBackground

                if let error = session.loadError {
                    VStack(spacing: AppSpacing.md) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.appIcon(28))
                            .foregroundStyle(Color.appMuted)
                        Text(error)
                            .font(.appCallout)
                            .foregroundStyle(Color.appMuted)
                    }
                } else if session.isComparing, let base = session.baseImage {
                    let rect = Self.fitted(CGSize(width: base.width, height: base.height), in: area)
                    image(base, in: rect)
                        .accessibilityLabel("Original image")
                } else if let preview = session.preview, session.sourceSize.width > 0 {
                    let showsCrop = session.tool == .crop
                    let content = showsCrop ? session.displayFrameSize : session.outputSize
                    let rect = Self.fitted(content, in: area)
                    image(preview, in: rect)
                        .accessibilityLabel("Edited image preview")
                    if showsCrop {
                        EditorCropOverlay(session: session, frame: rect)
                    }
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .clipped()
    }

    private func image(_ cgImage: CGImage, in rect: CGRect) -> some View {
        Image(decorative: cgImage, scale: 1)
            .resizable()
            .interpolation(.high)
            .frame(width: max(1, rect.width), height: max(1, rect.height))
            .position(x: rect.midX, y: rect.midY)
    }

    static func fitted(_ size: CGSize, in area: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0, area.width > 0, area.height > 0 else { return .zero }
        let scale = min(area.width / size.width, area.height / size.height)
        let width = size.width * scale, height = size.height * scale
        return CGRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
    }
}

// MARK: - Crop overlay

/// Where a crop drag started from.
enum EditCropHandle: String, CaseIterable, Identifiable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, move

    var id: String { rawValue }

    var isCorner: Bool { [.topLeft, .topRight, .bottomLeft, .bottomRight].contains(self) }

    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .top: return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        case .move: return CGPoint(x: rect.midX, y: rect.midY)
        }
    }

    var accessibilityName: String {
        switch self {
        case .topLeft: return "Top-left crop handle"
        case .top: return "Top crop edge"
        case .topRight: return "Top-right crop handle"
        case .right: return "Right crop edge"
        case .bottomRight: return "Bottom-right crop handle"
        case .bottom: return "Bottom crop edge"
        case .bottomLeft: return "Bottom-left crop handle"
        case .left: return "Left crop edge"
        case .move: return "Crop area"
        }
    }

    /// `start` (display space, normalized) dragged by (dx, dy) normalized. `ratio` locks
    /// width / height in normalized units (nil = free). Stays inside the unit square.
    static func dragged(_ start: EditRect, handle: EditCropHandle, dx: Double, dy: Double, ratio: Double?) -> EditRect {
        let minSize = EditGeometry.minimumCropFraction
        if handle == .move {
            return EditRect(
                x: min(max(0, start.x + dx), 1 - start.width),
                y: min(max(0, start.y + dy), 1 - start.height),
                width: start.width, height: start.height
            )
        }
        var minX = start.x, minY = start.y, maxX = start.maxX, maxY = start.maxY
        let movesLeft = [.topLeft, .left, .bottomLeft].contains(handle)
        let movesRight = [.topRight, .right, .bottomRight].contains(handle)
        let movesTop = [.topLeft, .top, .topRight].contains(handle)
        let movesBottom = [.bottomLeft, .bottom, .bottomRight].contains(handle)

        guard let ratio, ratio > 0 else {
            if movesLeft { minX = min(max(0, start.x + dx), maxX - minSize) }
            if movesRight { maxX = max(min(1, start.maxX + dx), minX + minSize) }
            if movesTop { minY = min(max(0, start.y + dy), maxY - minSize) }
            if movesBottom { maxY = max(min(1, start.maxY + dy), minY + minSize) }
            return EditRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }

        if handle.isCorner {
            // Anchor the opposite corner; follow whichever axis moved further.
            let anchorX = movesLeft ? start.maxX : start.x
            let anchorY = movesTop ? start.maxY : start.y
            let proposedW = start.width + (movesLeft ? -dx : dx)
            let proposedH = start.height + (movesTop ? -dy : dy)
            var width = max(proposedW, proposedH * ratio)
            let roomW = movesLeft ? anchorX : 1 - anchorX
            let roomH = movesTop ? anchorY : 1 - anchorY
            width = min(width, roomW, roomH * ratio)
            width = max(width, minSize * max(1, ratio))
            let height = width / ratio
            return EditRect(
                x: movesLeft ? anchorX - width : anchorX,
                y: movesTop ? anchorY - height : anchorY,
                width: width, height: height
            )
        }

        if movesTop || movesBottom {
            let anchorY = movesTop ? start.maxY : start.y
            var height = start.height + (movesTop ? -dy : dy)
            height = min(height, movesTop ? anchorY : 1 - anchorY, 1 / ratio)
            height = max(height, minSize * max(1, 1 / ratio))
            let width = height * ratio
            let x = min(max(0, start.midX - width / 2), 1 - width)
            return EditRect(x: x, y: movesTop ? anchorY - height : anchorY, width: width, height: height)
        }

        let anchorX = movesLeft ? start.maxX : start.x
        var width = start.width + (movesLeft ? -dx : dx)
        width = min(width, movesLeft ? anchorX : 1 - anchorX, ratio)
        width = max(width, minSize * max(1, ratio))
        let height = width / ratio
        let y = min(max(0, start.midY - height / 2), 1 - height)
        return EditRect(x: movesLeft ? anchorX - width : anchorX, y: y, width: width, height: height)
    }
}

struct EditorCropOverlay: View {
    @Bindable var session: EditorSession
    /// The displayed frame, in the canvas's coordinates.
    let frame: CGRect
    @State private var dragStart: EditRect?

    /// Normalized display-space width / height for the locked aspect.
    private var normalizedRatio: Double? {
        guard let output = session.lockedOutputRatio else { return nil }
        let size = session.displayFrameSize
        guard size.width > 0, size.height > 0 else { return nil }
        return output * Double(size.height / size.width)
    }

    var body: some View {
        let crop = session.displayCrop
        let rect = CGRect(
            x: frame.minX + CGFloat(crop.x) * frame.width,
            y: frame.minY + CGFloat(crop.y) * frame.height,
            width: CGFloat(crop.width) * frame.width,
            height: CGFloat(crop.height) * frame.height
        )
        ZStack {
            // Outside the crop recedes. On-image chrome is black / white in both
            // appearances, like every photo editor's.
            Path { path in
                path.addRect(frame)
                path.addRect(rect)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            EditorGridLines(rect: rect, divisions: session.isStraightening ? 9 : 3)
                .stroke(Color.white.opacity(session.isStraightening ? 0.35 : 0.5), lineWidth: 0.75)
                .allowsHitTesting(false)

            Path { $0.addRect(rect) }
                .stroke(Color.white, lineWidth: 1.5)
                .shadow(color: Color.black.opacity(0.5), radius: 1)
                .allowsHitTesting(false)

            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .frame(width: max(1, rect.width - 24), height: max(1, rect.height - 24))
                .position(x: rect.midX, y: rect.midY)
                .gesture(drag(.move))
                .accessibilityLabel(EditCropHandle.move.accessibilityName)

            ForEach(EditCropHandle.allCases.filter { $0 != .move }) { handle in
                handleView(handle)
                    .position(handle.point(in: rect))
                    .gesture(drag(handle))
                    .accessibilityLabel(handle.accessibilityName)
            }
        }
        .onHover { hovering in
            if !hovering { NSCursor.arrow.set() }
        }
    }

    @ViewBuilder
    private func handleView(_ handle: EditCropHandle) -> some View {
        ZStack {
            Color.clear.frame(width: 26, height: 26).contentShape(Rectangle())
            if handle.isCorner {
                Circle()
                    .fill(Color.white)
                    .frame(width: 11, height: 11)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.45), lineWidth: 1))
            } else {
                let horizontal = handle == .top || handle == .bottom
                Capsule()
                    .fill(Color.white)
                    .frame(width: horizontal ? 20 : 5, height: horizontal ? 5 : 20)
                    .overlay(Capsule().strokeBorder(Color.black.opacity(0.45), lineWidth: 1))
            }
        }
        .onHover { hovering in
            guard hovering else { return }
            switch handle {
            case .left, .right: NSCursor.resizeLeftRight.set()
            case .top, .bottom: NSCursor.resizeUpDown.set()
            default: NSCursor.crosshair.set()
            }
        }
    }

    private func drag(_ handle: EditCropHandle) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStart == nil {
                    dragStart = session.displayCrop
                    session.beginInteraction()
                }
                guard let start = dragStart, frame.width > 0, frame.height > 0 else { return }
                let dx = Double(value.translation.width / frame.width)
                let dy = Double(value.translation.height / frame.height)
                let candidate = EditCropHandle.dragged(start, handle: handle, dx: dx, dy: dy, ratio: normalizedRatio)
                session.proposeDisplayCrop(candidate)
            }
            .onEnded { _ in
                dragStart = nil
                session.endInteraction()
            }
    }
}

/// Rule-of-thirds (or a finer straighten) grid inside `rect`.
struct EditorGridLines: Shape {
    var rect: CGRect
    var divisions: Int

    func path(in _: CGRect) -> Path {
        var path = Path()
        guard divisions > 1, rect.width > 0, rect.height > 0 else { return path }
        for index in 1..<divisions {
            let fraction = CGFloat(index) / CGFloat(divisions)
            let x = rect.minX + rect.width * fraction
            let y = rect.minY + rect.height * fraction
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return path
    }
}
