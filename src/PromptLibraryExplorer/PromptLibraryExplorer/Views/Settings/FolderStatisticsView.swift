import SwiftUI

struct FolderStatistic: Identifiable {
    let id = UUID()
    let label: String
    let count: Int
    /// Decorative colour for the proportion bar.
    let color: Color
    /// Text-safe colour for the row glyph.
    var textColor: Color? = nil
    let icon: String

    init(label: String, count: Int, color: Color, textColor: Color? = nil, icon: String) {
        self.label = label
        self.count = count
        self.color = color
        self.textColor = textColor
        self.icon = icon
    }
}

struct FolderStatisticsView: View {
    @Environment(ExplorerViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    @State private var statistics: [FolderStatistic] = []
    @State private var totalSize: String = "Calculating..."
    @State private var dateDistribution: [(String, Int)] = []
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            header

            if isLoading {
                ProgressView("Analyzing folder...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        overviewCard
                        fileTypesCard
                        if !dateDistribution.isEmpty {
                            dateDistributionCard
                        }
                    }
                    .padding(20)
                }
            }

            footer
        }
        .frame(width: 560, height: 520)
        .background(Color.appBackground)
        .task {
            await computeStatistics()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .fill(Color.appElevatedSurface)
                Image(systemName: "chart.bar.fill")
                    .font(.appLargeTitle)
                    .foregroundStyle(Color.appAccent)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text("Folder Statistics")
                    .font(.appIcon(24, weight: .bold))
                    .foregroundStyle(Color.appPrimaryText)

                Text(vm.selectedFolderPath?.lastPathComponent ?? "No folder selected")
                    .font(.appIcon(14))
                    .foregroundStyle(Color.appMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(Color.appBackground)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.appBorder).frame(height: 1)
        }
    }

    private var overviewCard: some View {
        let totalItems = vm.folderContents.count
        let files = vm.folderContents.filter { !$0.isDirectory }.count
        let folders = vm.folderContents.filter { $0.isDirectory }.count

        return VStack(alignment: .leading, spacing: AppSpacing.lg) {
            Label("Overview", systemImage: "info.circle")
                .font(.appHeadline)
                .foregroundStyle(Color.appAccent)

            HStack(spacing: AppSpacing.xl) {
                statBox(label: "Total Items", value: "\(totalItems)", icon: "doc.on.doc")
                statBox(label: "Files", value: "\(files)", icon: "doc")
                statBox(label: "Folders", value: "\(folders)", icon: "folder")
            }

            HStack {
                Image(systemName: "internaldrive")
                    .foregroundStyle(Color.appMuted)
                Text("Total Size: \(totalSize)")
                    .font(.appBody)
                    .foregroundStyle(Color.appPrimaryText)
            }
        }
        .padding(AppSpacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .fill(Color.appSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .strokeBorder(Color.appBorder, lineWidth: 1)
        )
    }

    private var fileTypesCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            Label("File Types", systemImage: "square.grid.2x2")
                .font(.appHeadline)
                .foregroundStyle(Color.appAccent)

            if statistics.isEmpty {
                Text("No files in this folder")
                    .font(.appBody)
                    .foregroundStyle(Color.appMuted)
            } else {
                let totalFiles = statistics.reduce(0) { $0 + $1.count }

                ForEach(statistics) { stat in
                    HStack(spacing: 10) {
                        Image(systemName: stat.icon)
                            .foregroundStyle(stat.textColor ?? stat.color)
                            .frame(width: 18)

                        Text(stat.label)
                            .font(.appIcon(13, weight: .medium))
                            .foregroundStyle(Color.appPrimaryText)
                            .frame(width: 120, alignment: .leading)

                        GeometryReader { geometry in
                            let fraction = totalFiles > 0 ? CGFloat(stat.count) / CGFloat(totalFiles) : 0
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: AppRadius.xs)
                                    .fill(Color.appElevatedSurface)
                                RoundedRectangle(cornerRadius: AppRadius.xs)
                                    .fill(stat.color.opacity(0.7))
                                    .frame(width: max(2, geometry.size.width * fraction))
                            }
                        }
                        .frame(height: 12)

                        Text("\(stat.count)")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.appMuted)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
        }
        .padding(AppSpacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .fill(Color.appSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .strokeBorder(Color.appBorder, lineWidth: 1)
        )
    }

    private var dateDistributionCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            Label("Activity by Month", systemImage: "calendar")
                .font(.appHeadline)
                .foregroundStyle(Color.appAccent)

            let maxCount = dateDistribution.map(\.1).max() ?? 1

            ForEach(dateDistribution, id: \.0) { month, count in
                HStack(spacing: 10) {
                    Text(month)
                        .font(.appMono)
                        .foregroundStyle(Color.appMuted)
                        .frame(width: 70, alignment: .leading)

                    GeometryReader { geometry in
                        let fraction = CGFloat(count) / CGFloat(max(maxCount, 1))
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: AppRadius.xs)
                                .fill(Color.appElevatedSurface)
                            RoundedRectangle(cornerRadius: AppRadius.xs)
                                .fill(Color.appAccent.opacity(0.6))
                                .frame(width: max(2, geometry.size.width * fraction))
                        }
                    }
                    .frame(height: 12)

                    Text("\(count)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.appMuted)
                        .frame(width: 30, alignment: .trailing)
                }
            }
        }
        .padding(AppSpacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .fill(Color.appSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .strokeBorder(Color.appBorder, lineWidth: 1)
        )
    }

    private func statBox(label: String, value: String, icon: String) -> some View {
        VStack(spacing: AppSpacing.sm) {
            Image(systemName: icon)
                .font(.appIcon(18))
                .foregroundStyle(Color.appAccent)
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.appPrimaryText)
            Text(label)
                .font(.appCaption)
                .foregroundStyle(Color.appMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppSpacing.lg)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .fill(Color.appElevatedSurface)
        )
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, AppSpacing.xl)
        .background(Color.appBackground)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.appBorder).frame(height: 1)
        }
    }

    private func computeStatistics() async {
        guard vm.selectedFolderPath != nil else {
            isLoading = false
            return
        }

        let items = vm.folderContents.filter { !$0.isDirectory }

        // Count by type
        var plibCount = 0
        var aoeCount = 0
        var pngCount = 0
        var jpgCount = 0
        var webpCount = 0
        var gifCount = 0
        var otherImageCount = 0
        var otherCount = 0

        for item in items {
            let name = item.name.lowercased()
            if name.hasSuffix(".plib") { plibCount += 1 }
            else if name.hasSuffix(".aoe") { aoeCount += 1 }
            else if name.hasSuffix(".png") { pngCount += 1 }
            else if name.hasSuffix(".jpg") || name.hasSuffix(".jpeg") { jpgCount += 1 }
            else if name.hasSuffix(".webp") { webpCount += 1 }
            else if name.hasSuffix(".gif") { gifCount += 1 }
            else if FileHelpers.isImageFile(name) { otherImageCount += 1 }
            else { otherCount += 1 }
        }

        var stats: [FolderStatistic] = []
        if plibCount > 0 { stats.append(FolderStatistic(label: ".plib Files", count: plibCount, color: Color.appAccent, icon: "doc.text")) }
        if aoeCount > 0 { stats.append(FolderStatistic(label: ".aoe Files", count: aoeCount, color: Color.segmentStyle, textColor: Color.segmentStyleText, icon: "doc.richtext")) }
        if pngCount > 0 { stats.append(FolderStatistic(label: "PNG Images", count: pngCount, color: Color.segmentBrief, textColor: Color.segmentBriefText, icon: "photo")) }
        if jpgCount > 0 { stats.append(FolderStatistic(label: "JPEG Images", count: jpgCount, color: Color.segmentSubject, textColor: Color.segmentSubjectText, icon: "photo")) }
        if webpCount > 0 { stats.append(FolderStatistic(label: "WebP Images", count: webpCount, color: Color.segmentCamera, textColor: Color.segmentCameraText, icon: "photo")) }
        if gifCount > 0 { stats.append(FolderStatistic(label: "GIF Images", count: gifCount, color: Color.segmentLighting, textColor: Color.segmentLightingText, icon: "photo")) }
        if otherImageCount > 0 { stats.append(FolderStatistic(label: "Other Images", count: otherImageCount, color: Color.segmentPalette, textColor: Color.segmentPaletteText, icon: "photo")) }
        if otherCount > 0 { stats.append(FolderStatistic(label: "Other Files", count: otherCount, color: Color.appMuted, icon: "doc")) }

        stats.sort { $0.count > $1.count }

        // Total size
        var totalBytes: Int64 = 0
        let fm = FileManager.default
        for item in vm.folderContents {
            if let attrs = try? fm.attributesOfItem(atPath: item.path),
               let size = attrs[.size] as? Int64
            {
                totalBytes += size
            }
        }

        let sizeStr = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)

        // Date distribution
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM"
        var monthCounts: [String: Int] = [:]
        for item in items {
            if let attrs = try? fm.attributesOfItem(atPath: item.path),
               let modDate = attrs[.modificationDate] as? Date
            {
                let key = dateFormatter.string(from: modDate)
                monthCounts[key, default: 0] += 1
            }
        }
        let sortedMonths = monthCounts.sorted { $0.key > $1.key }.prefix(12).map { ($0.key, $0.value) }

        await MainActor.run {
            self.statistics = stats
            self.totalSize = sizeStr
            self.dateDistribution = Array(sortedMonths)
            self.isLoading = false
        }
    }
}
