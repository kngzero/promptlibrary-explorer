import AppKit
import SwiftUI

/// The last 200 ingest events, newest first. Used by the log sheet and inline
/// (limited) on Settings ▸ Ingest.
struct IngestLogList: View {
    var limit: Int?
    private var controller: IngestController { .shared }

    private var events: [IngestLogEvent] {
        let newestFirst = Array(controller.log.reversed())
        guard let limit else { return newestFirst }
        return Array(newestFirst.prefix(limit))
    }

    var body: some View {
        if events.isEmpty {
            Text("Nothing has happened yet. New files in watched folders are logged here.")
                .font(.appCallout)
                .foregroundStyle(Color.appMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            LazyVStack(alignment: .leading, spacing: AppSpacing.sm) {
                ForEach(events) { event in
                    IngestLogRow(event: event)
                }
            }
        }
    }
}

private struct IngestLogRow: View {
    let event: IngestLogEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.md) {
            Image(systemName: icon)
                .font(.appIcon(11, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 14)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(event.message)
                    .font(.appCallout)
                    .foregroundStyle(Color.appPrimaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text(detail)
                    .font(.appFootnote)
                    .foregroundStyle(Color.appMuted)
            }
            Spacer(minLength: 0)
            if let path = event.path, FileManager.default.fileExists(atPath: path) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: {
                    Image(systemName: "magnifyingglass.circle")
                        .font(.appCalloutEmphasis)
                }
                .buttonStyle(AppIconButtonStyle(width: 22, height: 22, cornerRadius: AppRadius.sm, showsRestingChrome: false))
                .help("Reveal in Finder")
                .accessibilityLabel("Reveal \((path as NSString).lastPathComponent) in Finder")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        let time = event.date.formatted(date: .abbreviated, time: .standard)
        return event.sourceName.map { "\($0) · \(time)" } ?? time
    }

    private var icon: String {
        switch event.level {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.circle"
        case .error: return "xmark.octagon"
        }
    }

    private var color: Color {
        switch event.level {
        case .info: return .appMuted
        case .warning: return .favoriteGoldText
        case .error: return .appError
        }
    }
}

/// Library ▸ Ingest Log… / the Inbox context menu / the status popover.
struct IngestLogSheet: View {
    @Environment(\.dismiss) private var dismiss
    private var controller: IngestController { .shared }

    var body: some View {
        VStack(spacing: 0) {
            FeatureSheetHeader(
                title: "Ingest Log",
                subtitle: "Last \(IngestStore.maxLogEvents) events from watched folders",
                systemImage: "list.bullet.rectangle",
                onClose: { dismiss() }
            )
            ScrollView {
                IngestLogList()
                    .padding(AppSpacing.xl)
            }
            .background(Color.appBackground)
            FeatureSheetFooter {
                Button("Clear Log") { controller.clearLog() }
                    .buttonStyle(AppLabeledButtonStyle())
                    .disabled(controller.log.isEmpty)
                    .accessibilityHint("Empties the log. Files are not affected.")
                Spacer(minLength: 0)
                Text("\(controller.log.count) event\(controller.log.count == 1 ? "" : "s")")
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
            }
        }
        .frame(width: 600, height: 520)
        .background(Color.appBackground)
    }
}

/// Presents the ingest log sheet on the main window. Applied once in the App file.
struct IngestSheetsHost: ViewModifier {
    @Bindable private var controller = IngestController.shared

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $controller.logSheetOpen) {
                IngestLogSheet()
            }
    }
}

extension View {
    func ingestSheetsHost() -> some View {
        modifier(IngestSheetsHost())
    }
}
