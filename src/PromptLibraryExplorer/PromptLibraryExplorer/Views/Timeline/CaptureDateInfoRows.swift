import SwiftUI

/// Details panel ▸ File Info: the file's "Date" (capture date, else creation,
/// else modification date, saying which) and, for geotagged files, its
/// location with Show on Map. Read from the library index, else the file.
struct CaptureDateInfoRows: View {
    @Environment(ExplorerViewModel.self) private var vm
    let path: String

    @State private var resolved: ResolvedCaptureDate?
    @State private var coordinate: GeoCoordinate?

    var body: some View {
        Group {
            if let resolved {
                row(label: "Date") {
                    VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                        Text(Self.format(resolved))
                            .font(.appCaption)
                            .foregroundStyle(Color.appPrimaryText)
                            .textSelection(.enabled)
                        Text(sourceText(resolved))
                            .font(.appFootnote)
                            .foregroundStyle(Color.appMuted)
                    }
                }
                .help(helpText(resolved))
            }
            if let coordinate {
                row(label: "Location") {
                    VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                        Text(vm.mapTimeline.placeName(for: coordinate) ?? coordinate.displayString)
                            .font(.appCaption)
                            .foregroundStyle(Color.appPrimaryText)
                            .textSelection(.enabled)
                        if let altitude = coordinate.altitude {
                            Text(String(format: "%.0f m %@", abs(altitude), altitude < 0 ? "below sea level" : "altitude"))
                                .font(.appFootnote)
                                .foregroundStyle(Color.appMuted)
                        }
                        Button("Show on Map") {
                            vm.showOnMap(vm.mapTimelineEntry(for: path))
                        }
                        .buttonStyle(.link)
                        .font(.appFootnote)
                    }
                }
            }
        }
        .task(id: path) {
            resolved = nil
            coordinate = nil
            let entry = vm.mapTimelineEntry(for: path)
            guard !entry.isDirectory else { return }
            let fileDates = CaptureDateResolver.resolve(capture: nil, created: entry.creationDate, modified: entry.modifiedDate)
            resolved = fileDates
            let capture = await vm.mapTimeline.capture(for: entry)
            guard !Task.isCancelled else { return }
            resolved = CaptureDateResolver.resolve(capture: capture, created: entry.creationDate, modified: entry.modifiedDate)
            coordinate = capture.coordinate
        }
    }

    private func row<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            Text(label)
                .font(.appCaption)
                .foregroundStyle(Color.appMuted)
                .frame(width: 70, alignment: .leading)
            content()
        }
    }

    private func sourceText(_ resolved: ResolvedCaptureDate) -> String {
        resolved.source.title
    }

    private func helpText(_ resolved: ResolvedCaptureDate) -> String {
        switch resolved.source {
        case .captured:
            return "Captured: from the file's \(resolved.origin?.title ?? "embedded date")"
        case .created:
            return "Created: the file has no embedded capture date, so its creation date is used"
        case .modified:
            return "Modified: the file has no capture or creation date, so its modification date is used"
        }
    }

    /// In the capture's own time zone when the file says what it was.
    static func format(_ resolved: ResolvedCaptureDate) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        if let offset = resolved.utcOffset, let zone = TimeZone(secondsFromGMT: offset) {
            formatter.timeZone = zone
        }
        return formatter.string(from: resolved.date)
    }
}
