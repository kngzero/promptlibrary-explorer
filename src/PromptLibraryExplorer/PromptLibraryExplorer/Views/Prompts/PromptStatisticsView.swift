import SwiftUI

/// Library ▸ Prompt Statistics…: what the folder or whole library is made of —
/// top words and phrases, model usage over time, sampler / steps / CFG
/// distributions, rating and pick rate by model and sampler, files per day.
/// Click a word, phrase, model or sampler to find those files.
///
/// Charts follow one system: a single accent hue for magnitude (no colour
/// identity to decode), recessive tracks, values in text tokens, hover help
/// on every bar.
struct PromptStatisticsView: View {
    @Environment(ExplorerViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    @State private var scope: PromptStatisticsScope
    @State private var rows: [PromptStatsRow] = []
    @State private var report = PromptStatsReport()
    @State private var isLoading = true
    @State private var monthModel = ""

    init(request: PromptStatisticsRequest) {
        _scope = State(initialValue: request.scope)
    }

    var body: some View {
        VStack(spacing: 0) {
            FeatureSheetHeader(
                title: "Prompt Statistics",
                subtitle: scopeSubtitle,
                systemImage: "chart.bar.xaxis",
                onClose: close
            ) {
                Picker("Scope", selection: $scope) {
                    ForEach(PromptStatisticsScope.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(isLoading)
            }

            Group {
                if isLoading {
                    ProgressView(scope == .library ? "Reading the library index…" : "Reading this folder…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if report.isEmpty {
                    FeatureEmptyState(
                        systemImage: "chart.bar",
                        title: "Nothing to count yet",
                        message: scope == .library
                            ? "The library index is empty. Library ▸ Reindex Library builds it."
                            : "This folder has no images or prompt files."
                    )
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            overview
                            HStack(alignment: .top, spacing: 18) {
                                topWordsCard
                                topPhrasesCard
                            }
                            monthlyCard
                            qualityCard(title: "Models", systemImage: "cpu", groups: report.qualityByModel, isModel: true)
                            if !report.qualityBySampler.isEmpty {
                                qualityCard(title: "Samplers", systemImage: "dial.medium", groups: report.qualityBySampler, isModel: false)
                            }
                            if !report.steps.isEmpty || !report.cfg.isEmpty {
                                HStack(alignment: .top, spacing: 18) {
                                    distributionCard(title: "Steps", systemImage: "stairs", counts: report.steps)
                                    distributionCard(title: "CFG", systemImage: "gauge.with.dots.needle.33percent", counts: report.cfg)
                                }
                            }
                            if !report.days.isEmpty { daysCard }
                        }
                        .padding(20)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            FeatureSheetFooter {
                Text("Words and phrases count once per file (common words left out). Ratings and picks are your curation data.")
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
                Spacer()
            }
        }
        .frame(width: 900, height: 780)
        .background(Color.appBackground)
        .task(id: scope) { await load() }
    }

    private var scopeSubtitle: String {
        switch scope {
        case .folder: return vm.activeVirtualListing?.title ?? vm.selectedFolderPath?.lastPathComponent ?? "This folder"
        case .library: return vm.explorerRootPath.map { "\($0.lastPathComponent) and every subfolder" } ?? "Library"
        }
    }

    private func load() async {
        isLoading = true
        let loaded = await vm.loadPromptStatsRows(scope: scope)
        guard !Task.isCancelled else { return }
        let computed = await Task.detached(priority: .userInitiated) { PromptStatsService.report(for: loaded) }.value
        guard !Task.isCancelled else { return }
        rows = loaded
        report = computed
        if !monthModel.isEmpty, !computed.models.contains(where: { $0.label == monthModel }) { monthModel = "" }
        isLoading = false
    }

    // MARK: Overview

    private var overview: some View {
        let rated = report.qualityByModel.reduce(0) { $0 + $1.ratedCount }
        let picks = report.qualityByModel.reduce(0) { $0 + $1.pickCount }
        return HStack(spacing: AppSpacing.lg) {
            statBox("Files", value: report.fileCount, icon: "doc.on.doc")
            statBox("With a prompt", value: report.promptCount, icon: "text.quote")
            statBox("Models", value: report.models.filter { $0.label != PromptStatsService.unknownModel }.count, icon: "cpu")
            statBox("Rated", value: rated, icon: "star")
            statBox("Picks", value: picks, icon: "flag")
        }
    }

    private func statBox(_ label: String, value: Int, icon: String) -> some View {
        VStack(spacing: AppSpacing.sm) {
            Image(systemName: icon)
                .font(.appIcon(16))
                .foregroundStyle(Color.appAccent)
            Text("\(value)")
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.appPrimaryText)
            Text(label)
                .font(.appCaption)
                .foregroundStyle(Color.appMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppSpacing.lg)
        .background(RoundedRectangle(cornerRadius: AppRadius.lg).fill(Color.appSurface))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.lg).strokeBorder(Color.appBorder, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    // MARK: Words and phrases

    private var topWordsCard: some View {
        PromptSheetCard(title: "Top Words", systemImage: "textformat") {
            if report.topTokens.isEmpty {
                emptyNote("No prompt text.")
            } else {
                PromptFlowLayout(spacing: AppSpacing.xs, lineSpacing: AppSpacing.xs) {
                    ForEach(report.topTokens) { token in
                        Button {
                            vm.searchLibrary(forPhrase: token.label)
                        } label: {
                            HStack(spacing: AppSpacing.xs) {
                                Text(token.label)
                                    .font(.appCaption)
                                    .foregroundStyle(Color.appPrimaryText)
                                Text("\(token.count)")
                                    .font(.appCaption.monospacedDigit())
                                    .foregroundStyle(Color.appMuted)
                            }
                            .padding(.horizontal, AppSpacing.sm)
                            .padding(.vertical, AppSpacing.xxs + 1)
                            .background(Capsule().fill(Color.appElevatedSurface))
                            .overlay(Capsule().strokeBorder(Color.appBorder, lineWidth: 1))
                        }
                        .buttonStyle(AppAdaptiveButtonStyle())
                        .help("\(token.label): in \(token.count) files. Click to find them in the library.")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var topPhrasesCard: some View {
        PromptSheetCard(title: "Top Phrases", systemImage: "text.word.spacing") {
            if report.topPhrases.isEmpty {
                emptyNote("No phrase appears in more than one file.")
            } else {
                let maxCount = report.topPhrases.map(\.count).max() ?? 1
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    ForEach(report.topPhrases.prefix(15)) { phrase in
                        Button {
                            vm.searchLibrary(forPhrase: phrase.label)
                        } label: {
                            barRow(label: phrase.label, count: phrase.count, maxCount: maxCount, labelWidth: 150)
                        }
                        .buttonStyle(AppAdaptiveButtonStyle())
                        .help("“\(phrase.label)”: in \(phrase.count) files. Click to find them in the library.")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Model usage over time

    private var monthlyCard: some View {
        let topModels = report.models.prefix(10)
        let values = report.months.map { month in
            monthModel.isEmpty ? month.total : (month.byModel[monthModel] ?? 0)
        }
        let maxValue = max(values.max() ?? 0, 1)
        return PromptSheetCard(title: "Model Usage by Month", systemImage: "calendar") {
            if report.months.isEmpty {
                emptyNote("No dated files.")
            } else {
                HStack {
                    Picker("Model", selection: $monthModel) {
                        Text("All models").tag("")
                        ForEach(topModels) { model in
                            Text("\(model.label) (\(model.count))").tag(model.label)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                    Text("Peak \(values.max() ?? 0) files / month")
                        .font(.appCaption)
                        .foregroundStyle(Color.appMuted)
                }
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(Array(report.months.enumerated()), id: \.element.id) { index, month in
                        let value = values[index]
                        VStack(spacing: AppSpacing.xs) {
                            ZStack(alignment: .bottom) {
                                Rectangle().fill(Color.clear)
                                UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4)
                                    .fill(Color.appAccent.opacity(value == 0 ? 0 : 0.75))
                                    .frame(height: max(value == 0 ? 0 : 2, 140 * CGFloat(value) / CGFloat(maxValue)))
                            }
                            .frame(height: 140)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(Color.appControlBorder).frame(height: 1)
                            }
                            Text(monthLabel(month.month, index: index, count: report.months.count))
                                .font(.appMicro)
                                .foregroundStyle(Color.appMuted)
                                .lineLimit(1)
                                .fixedSize()
                                .frame(height: 12)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .help(monthHelp(month, value: value))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(monthHelp(month, value: value))
                    }
                }
            }
        }
    }

    /// First, last and every sixth month get a label; others stay blank to avoid collisions.
    private func monthLabel(_ key: String, index: Int, count: Int) -> String {
        guard index == 0 || index == count - 1 || index % 6 == 0 else { return "" }
        let parts = key.split(separator: "-")
        guard parts.count == 2, let month = Int(parts[1]) else { return key }
        let names = Calendar.current.shortMonthSymbols
        return "\(names[max(0, min(11, month - 1))]) \(parts[0].suffix(2))"
    }

    private func monthHelp(_ month: PromptStatsMonth, value: Int) -> String {
        var text = "\(month.month): \(value) file\(value == 1 ? "" : "s")"
        if monthModel.isEmpty, !month.byModel.isEmpty {
            let top = month.byModel.sorted { $0.value > $1.value }.prefix(3)
                .map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            text += " — " + top
        }
        return text
    }

    // MARK: Quality by model / sampler

    private func qualityCard(title: String, systemImage: String, groups: [PromptStatsGroupQuality], isModel: Bool) -> some View {
        let shown = Array(groups.prefix(isModel ? 15 : 12))
        let maxCount = shown.map(\.count).max() ?? 1
        return PromptSheetCard(title: title, systemImage: systemImage) {
            HStack(spacing: AppSpacing.md) {
                Text(isModel ? "Model" : "Sampler").frame(width: 200, alignment: .leading)
                Text("Files").frame(maxWidth: .infinity, alignment: .leading)
                Text("Avg rating").frame(width: 80, alignment: .trailing)
                Text("Pick rate").frame(width: 70, alignment: .trailing)
            }
            .font(.appCaptionEmphasis)
            .foregroundStyle(Color.appMuted)

            ForEach(shown) { group in
                Button {
                    let paths = isModel
                        ? PromptStatsService.paths(in: rows, model: group.name)
                        : PromptStatsService.paths(in: rows, sampler: group.name)
                    vm.showPromptStatsListing(title: "\(isModel ? "Model" : "Sampler"): \(group.name)", paths: paths)
                } label: {
                    HStack(spacing: AppSpacing.md) {
                        Text(group.name)
                            .font(.appCallout)
                            .foregroundStyle(Color.appPrimaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(width: 200, alignment: .leading)
                        bar(count: group.count, maxCount: maxCount)
                        Text(group.averageRating.map { String(format: "★ %.1f", $0) } ?? "—")
                            .font(.appCallout.monospacedDigit())
                            .foregroundStyle(group.averageRating == nil ? Color.appMuted : Color.favoriteGoldText)
                            .frame(width: 80, alignment: .trailing)
                        Text(group.pickCount == 0 ? "—" : String(format: "%.0f%%", group.pickRate * 100))
                            .font(.appCallout.monospacedDigit())
                            .foregroundStyle(group.pickCount == 0 ? Color.appMuted : Color.appPrimaryText)
                            .frame(width: 70, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(AppAdaptiveButtonStyle())
                .help(qualityHelp(group))
            }
            if groups.count > shown.count {
                Text("\(groups.count - shown.count) more not shown")
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
            }
        }
    }

    private func qualityHelp(_ group: PromptStatsGroupQuality) -> String {
        var text = "\(group.name): \(group.count) files, \(group.ratedCount) rated"
        if let average = group.averageRating { text += String(format: " (avg %.2f★)", average) }
        text += ", \(group.pickCount) picks, \(group.rejectCount) rejects. Click to list these files."
        return text
    }

    // MARK: Distributions

    private func distributionCard(title: String, systemImage: String, counts: [PromptStatsCount]) -> some View {
        let maxCount = counts.map(\.count).max() ?? 1
        return PromptSheetCard(title: title, systemImage: systemImage) {
            if counts.isEmpty {
                emptyNote("No \(title.lowercased()) values recorded.")
            } else {
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    ForEach(counts) { item in
                        barRow(label: item.label, count: item.count, maxCount: maxCount, labelWidth: 50)
                            .help("\(title) \(item.label): \(item.count) files")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Files per day

    private var daysCard: some View {
        let maxCount = max(report.days.map(\.count).max() ?? 0, 1)
        return PromptSheetCard(title: "Files per Day", systemImage: "calendar.day.timeline.left") {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(report.days) { day in
                    ZStack(alignment: .bottom) {
                        Rectangle().fill(Color.clear)
                        UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2)
                            .fill(Color.appAccent.opacity(day.count == 0 ? 0 : 0.75))
                            .frame(height: max(day.count == 0 ? 0 : 2, 70 * CGFloat(day.count) / CGFloat(maxCount)))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 70)
                    .contentShape(Rectangle())
                    .help("\(day.label): \(day.count) file\(day.count == 1 ? "" : "s")")
                    .accessibilityLabel("\(day.label): \(day.count) files")
                }
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.appControlBorder).frame(height: 1)
            }
            HStack {
                Text(report.days.first?.label ?? "")
                Spacer()
                Text("Peak \(maxCount) / day")
                Spacer()
                Text(report.days.last?.label ?? "")
            }
            .font(.appCaption)
            .foregroundStyle(Color.appMuted)
        }
    }

    // MARK: Pieces

    private func barRow(label: String, count: Int, maxCount: Int, labelWidth: CGFloat) -> some View {
        HStack(spacing: AppSpacing.md) {
            Text(label)
                .font(.appCallout)
                .foregroundStyle(Color.appPrimaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: labelWidth, alignment: .leading)
            bar(count: count, maxCount: maxCount)
        }
        .contentShape(Rectangle())
    }

    private func bar(count: Int, maxCount: Int) -> some View {
        HStack(spacing: AppSpacing.sm) {
            GeometryReader { geometry in
                let fraction = CGFloat(count) / CGFloat(max(maxCount, 1))
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: AppRadius.xs).fill(Color.appElevatedSurface)
                    RoundedRectangle(cornerRadius: AppRadius.xs)
                        .fill(Color.appAccent.opacity(0.7))
                        .frame(width: max(2, geometry.size.width * fraction))
                }
            }
            .frame(height: 10)
            Text("\(count)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.appMuted)
                .frame(width: 44, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(.appCallout)
            .foregroundStyle(Color.appMuted)
    }

    private func close() {
        vm.promptWorkflows.statisticsRequest = nil
        dismiss()
    }
}
