import SwiftUI
import KodauCore

/// Combined progress + usage tab: one hero number (offline share), three aligned secondary
/// metrics, then Gemini usage/cost with the daily quota, and the roadmap phases collapsed.
public struct StatsView: View {
    @EnvironmentObject private var appState: AppState

    @State private var selectedPeriod: UsagePeriod = .day
    @State private var breakdownBuckets: [UsageBreakdownBucket] = []
    @State private var exchangeRateInput: String = ""
    @State private var exchangeRateFeedback: String? = nil
    @State private var showResetConfirm: Bool = false
    @State private var showRoadmap: Bool = false
    @State private var showBreakdown: Bool = false
    @State private var showPricing: Bool = false

    public init() {}

    public var body: some View {
        PageScaffold("Thống kê", subtitle: "Mức độ độc lập offline và chi phí Gemini.") {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.md) {
                    heroCard
                    secondaryMetrics
                    geminiCard
                    roadmapCard
                }
                .padding(.horizontal, Space.lg)
                .padding(.bottom, Space.lg)
            }
        }
        .onAppear {
            syncExchangeRateField()
            reloadUsageData()
        }
        .onChange(of: selectedPeriod) { _, _ in
            reloadBreakdown()
        }
        .onChange(of: appState.usageSummaries) { _, _ in
            reloadBreakdown()
        }
        .onChange(of: appState.config.usdToVndRate) { _, _ in
            syncExchangeRateField()
            reloadUsageData()
        }
        .alert("Đặt lại thống kê API?", isPresented: $showResetConfirm) {
            Button("Hủy", role: .cancel) {}
            Button("Đặt lại", role: .destructive) {
                appState.store.resetAPIUsage()
                reloadUsageData()
            }
        } message: {
            Text("Toàn bộ token và chi phí ước tính đã ghi sẽ về 0. Từ điển và API Key vẫn giữ nguyên.")
        }
    }

    // MARK: - Hero

    private var heroCard: some View {
        let stats = appState.stats
        let offlineShare = Int((stats.offlineHitRate * 100).rounded())
        let isOffline = appState.config.brainStrategy == .offlineOnly

        return VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .top, spacing: Space.lg) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(offlineShare)")
                            .font(Typography.hero)
                            .monospacedDigit()
                        Text("%")
                            .font(Typography.metric)
                            .foregroundStyle(.secondary)
                    }
                    Text("xử lý offline")
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 132, alignment: .leading)

                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack(spacing: Space.xs) {
                        Text(stats.stage.title)
                            .font(Typography.section)
                        if isOffline {
                            Label("Đang offline", systemImage: "checkmark.circle")
                                .font(Typography.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("\(stats.localConversions) cục bộ · \(stats.geminiConversions) qua Gemini · \(stats.totalConversions) lượt")
                        .font(Typography.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: Space.xxs) {
                        ProgressView(value: stats.independenceScore)
                            .tint(isOffline ? Color.green : Color.accentColor)
                        Text("Tiến độ lên Giai đoạn 4")
                            .font(Typography.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.top, Space.xxs)
                }

                Spacer(minLength: Space.sm)

                heroAction(isOffline: isOffline)
            }

            if appState.showOfflineReadyBanner {
                Divider()
                HStack(spacing: Space.xs) {
                    Image(systemName: "checkmark.seal")
                        .font(Typography.caption)
                        .foregroundStyle(.green)
                    Text("Bộ nhớ đã đủ mạnh để chạy 100% offline.")
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: Space.xs)
                }
            }

            if let last = appState.lastConversion {
                Divider()
                HStack(spacing: Space.xs) {
                    Text("Gần nhất")
                        .font(Typography.caption)
                        .foregroundStyle(.tertiary)
                    Text(last.convertedText)
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: Space.xs)
                    Text(last.source.label)
                        .font(Typography.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .kodauCard(padding: Space.md + 2)
    }

    @ViewBuilder
    private func heroAction(isOffline: Bool) -> some View {
        if isOffline {
            Button("Bật lại Hybrid") {
                appState.setStrategy(.hybrid)
            }
            .buttonStyle(.bordered)
            .help("Cho phép gọi Gemini khi bộ nhớ offline chưa đủ chắc.")
        } else {
            Button("Chuyển sang 100% Offline") {
                appState.switchToOfflineOnly()
            }
            .buttonStyle(.borderedProminent)
            .help("Không gọi API nữa — chỉ dùng bộ nhớ cục bộ.")
        }
    }

    // MARK: - Secondary metrics

    private var secondaryMetrics: some View {
        let stats = appState.stats
        return HStack(spacing: Space.sm) {
            metricCard(
                title: "Từ vựng",
                value: stats.uniqueWordsLearned,
                detail: "\(stats.uniqueBigramsLearned) ngữ cảnh cặp từ"
            )
            metricCard(
                title: "Cụm từ",
                value: stats.uniquePhrasesLearned,
                detail: "\(stats.totalConversions) lượt chuyển đổi"
            )
            metricCard(
                title: "Lượt bạn dạy",
                value: stats.userCorrections,
                detail: "được ưu tiên khi suy đoán"
            )
        }
    }

    private func metricCard(title: String, value: Int, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Typography.caption)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(Typography.metric)
                .monospacedDigit()
            Text(detail)
                .font(Typography.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .kodauCard(padding: Space.sm + 2)
    }

    // MARK: - Gemini usage

    private var geminiCard: some View {
        let summary = activeSummary
        let today = summaryFor(.day)
        let callLimit = appState.config.dailyGeminiCallLimit
        let budget = appState.config.dailyGeminiBudgetVND
        let callsExhausted = callLimit > 0 && today.apiCalls >= callLimit
        let budgetExhausted = budget > 0 && today.costVND >= budget

        return VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.xs) {
                Text("Gemini")
                    .font(Typography.section)

                Text(appState.config.geminiModel)
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Button("Đổi") {
                    appState.selectedTab = .settings
                }
                .buttonStyle(.borderless)
                .font(Typography.caption)
                .foregroundStyle(.secondary)
                .help("Đổi API Key và model trong Cài đặt")

                Spacer(minLength: Space.xs)

                Button {
                    reloadUsageData()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Làm mới")
            }

            Picker("Kỳ", selection: $selectedPeriod) {
                ForEach(UsagePeriod.allCases) { period in
                    Text(period.title).tag(period)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(alignment: .top, spacing: Space.md) {
                usageColumn(
                    title: "Lượt gọi",
                    value: formatInt(summary.apiCalls),
                    detail: summary.apiCalls > 0
                        ? "≈ \(formatInt(avgTokens(summary))) token/lượt"
                        : "chưa gọi API"
                )
                Divider().frame(height: 34)
                usageColumn(
                    title: "Chi phí",
                    value: formatVND(summary.costVND),
                    detail: formatUSD(summary.costUSD)
                )
                Divider().frame(height: 34)
                usageColumn(
                    title: "Token",
                    value: formatInt(summary.totalTokens),
                    detail: "vào \(formatInt(summary.promptTokens)) · ra \(formatInt(summary.outputTokens))"
                )
            }

            Divider()

            VStack(alignment: .leading, spacing: Space.xs) {
                HStack {
                    Text("Hạn mức hôm nay")
                        .font(Typography.captionMedium)
                    Spacer()
                    if callsExhausted || budgetExhausted {
                        Label("Đã chạm hạn mức — chạy offline đến hết ngày", systemImage: "exclamationmark.circle")
                            .font(Typography.caption)
                            .foregroundStyle(.orange)
                    }
                }

                quotaMeter(
                    label: "Lượt gọi",
                    used: formatInt(today.apiCalls),
                    limit: callLimit > 0 ? formatInt(callLimit) : nil,
                    fraction: callLimit > 0 ? Double(today.apiCalls) / Double(callLimit) : nil,
                    exhausted: callsExhausted
                )
                quotaMeter(
                    label: "Chi phí",
                    used: formatVND(today.costVND),
                    limit: budget > 0 ? formatVND(budget) : nil,
                    fraction: budget > 0 ? today.costVND / budget : nil,
                    exhausted: budgetExhausted
                )
            }

            DisclosureGroup(isExpanded: $showBreakdown) {
                breakdownRows
                    .padding(.top, Space.xxs)
            } label: {
                Text("Chi tiết theo thời gian")
                    .font(Typography.captionMedium)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup(isExpanded: $showPricing) {
                pricingAndControls
                    .padding(.top, Space.xxs)
            } label: {
                Text("Bảng giá model & tỷ giá")
                    .font(Typography.captionMedium)
                    .foregroundStyle(.secondary)
            }
        }
        .kodauCard()
    }

    private func usageColumn(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(Typography.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(Typography.metric)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail)
                .font(Typography.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func quotaMeter(
        label: String,
        used: String,
        limit: String?,
        fraction: Double?,
        exhausted: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(limit.map { "\(used) / \($0)" } ?? used)
                    .font(Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if let fraction {
                ProgressView(value: min(1.0, max(0.0, fraction)))
                    .tint(exhausted ? Color.orange : Color.accentColor)
            } else {
                Text("Không giới hạn")
                    .font(Typography.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var breakdownRows: some View {
        let maxTokens = max(1, breakdownBuckets.map(\.totalTokens).max() ?? 1)
        return VStack(alignment: .leading, spacing: Space.xs) {
            if breakdownBuckets.isEmpty {
                Text("Chưa có lượt gọi Gemini nào trong kỳ này.")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(breakdownBuckets) { bucket in
                    let ratio = min(1.0, max(0.02, Double(bucket.totalTokens) / Double(maxTokens)))
                    HStack(spacing: Space.xs) {
                        Text(bucket.label)
                            .font(Typography.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 88, alignment: .leading)
                            .lineLimit(1)

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(Color.primary.opacity(0.06))
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.7))
                                    .frame(width: max(3, geo.size.width * ratio))
                            }
                        }
                        .frame(height: 6)

                        Text(formatVND(bucket.costVND))
                            .font(Typography.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 78, alignment: .trailing)
                        Text("\(formatInt(bucket.totalTokens)) tok")
                            .font(Typography.caption)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                            .frame(width: 84, alignment: .trailing)
                    }
                }
            }
        }
    }

    private var pricingAndControls: some View {
        let activeLower = appState.config.geminiModel.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        return VStack(alignment: .leading, spacing: Space.sm) {
            VStack(spacing: Space.xxs + 2) {
                ForEach(GeminiModelPricing.catalog) { item in
                    let isCurrent = item.modelID.lowercased() == activeLower
                    HStack(spacing: Space.xs) {
                        Text(item.displayName)
                            .font(Typography.caption)
                            .foregroundStyle(isCurrent ? .primary : .secondary)
                        if isCurrent {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Color.accentColor)
                        }
                        Spacer(minLength: Space.xs)
                        Text(formatPriceUSD(item.inputPerMillionUSD))
                            .font(Typography.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 66, alignment: .trailing)
                        Text(formatPriceUSD(item.outputPerMillionUSD))
                            .font(Typography.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 66, alignment: .trailing)
                        Button(isCurrent ? "Đang dùng" : "Chọn") {
                            appState.config.geminiModel = item.modelID
                            appState.saveConfig()
                            reloadUsageData()
                        }
                        .buttonStyle(.borderless)
                        .font(Typography.caption)
                        .disabled(isCurrent)
                        .frame(width: 62, alignment: .trailing)
                    }
                }

                HStack {
                    Text("USD / 1M token — vào · ra")
                        .font(Typography.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.top, Space.xxs)
            }

            Divider()

            HStack(spacing: Space.xs) {
                Text("Tỷ giá")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                TextField("25800", text: $exchangeRateInput)
                    .textFieldStyle(.roundedBorder)
                    .font(Typography.caption)
                    .frame(width: 88)
                    .onSubmit { applyExchangeRate() }
                Text("₫/USD")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)

                Button("Lưu") { applyExchangeRate() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Button("Mặc định") {
                    appState.config.usdToVndRate = 25_800
                    appState.saveConfig()
                    syncExchangeRateField()
                    exchangeRateFeedback = "Đã đặt lại 25.800 ₫/USD."
                    reloadUsageData()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer(minLength: Space.xs)

                Button("Đặt lại thống kê") {
                    showResetConfirm = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if let feedback = exchangeRateFeedback {
                Text(feedback)
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Roadmap

    private var roadmapCard: some View {
        let currentStage = appState.stats.stage

        return VStack(alignment: .leading, spacing: Space.xs) {
            DisclosureGroup(isExpanded: $showRoadmap) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    ForEach(IndependenceStage.allCases, id: \.rawValue) { stage in
                        let isCompleted = stage.rawValue < currentStage.rawValue
                        let isCurrent = stage == currentStage
                        HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                            Image(systemName: isCompleted
                                  ? "checkmark.circle.fill"
                                  : (isCurrent ? "circle.inset.filled" : "circle"))
                                .font(Typography.caption)
                                .foregroundStyle(isCompleted ? Color.secondary : (isCurrent ? Color.accentColor : Color.secondary.opacity(0.5)))

                            VStack(alignment: .leading, spacing: 1) {
                                Text(stage.title)
                                    .font(Typography.bodyMedium)
                                    .foregroundStyle(isCurrent || isCompleted ? .primary : .secondary)
                                Text(stage.description)
                                    .font(Typography.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 1)
                    }
                }
                .padding(.top, Space.xs)
            } label: {
                HStack(spacing: Space.xs) {
                    Text("Lộ trình 4 giai đoạn")
                        .font(Typography.section)
                    Text("đang ở \(currentStage.title)")
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .kodauCard()
    }

    // MARK: - Data helpers

    private var activeSummary: UsageSummary {
        summaryFor(selectedPeriod)
    }

    private func summaryFor(_ period: UsagePeriod) -> UsageSummary {
        if let cached = appState.usageSummaries.first(where: { $0.period == period }) {
            return cached
        }
        return appState.store.fetchUsageSummary(
            period: period,
            usdToVndRate: appState.config.usdToVndRate
        )
    }

    private func avgTokens(_ summary: UsageSummary) -> Int {
        guard summary.apiCalls > 0 else { return 0 }
        return Int((Double(summary.totalTokens) / Double(summary.apiCalls)).rounded())
    }

    private var currentRate: Double {
        max(1_000, appState.config.usdToVndRate)
    }

    private func reloadUsageData() {
        appState.refreshStats()
        reloadBreakdown()
    }

    private func reloadBreakdown() {
        breakdownBuckets = appState.store.fetchUsageBreakdown(
            period: selectedPeriod,
            usdToVndRate: currentRate
        )
    }

    private func syncExchangeRateField() {
        exchangeRateInput = String(Int(currentRate.rounded()))
    }

    private func applyExchangeRate() {
        let cleaned = exchangeRateInput
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let parsed = Double(cleaned), parsed >= 1_000, parsed <= 200_000 else {
            exchangeRateFeedback = "Tỷ giá hợp lệ: 1.000 – 200.000 ₫/USD."
            return
        }
        appState.config.usdToVndRate = parsed
        appState.saveConfig()
        exchangeRateFeedback = "Đã cập nhật \(formatVND(parsed))/USD."
        reloadUsageData()
    }

    // MARK: - Formatting

    private static let intFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = "."
        f.decimalSeparator = ","
        f.maximumFractionDigits = 0
        return f
    }()

    private func formatInt(_ value: Int) -> String {
        Self.intFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func formatVND(_ amount: Double) -> String {
        if amount <= 0 { return "0 ₫" }
        if amount < 1.0 {
            return String(format: "%.2f ₫", amount).replacingOccurrences(of: ".", with: ",")
        }
        let rounded = Int(amount.rounded())
        let formatted = Self.intFormatter.string(from: NSNumber(value: rounded)) ?? "\(rounded)"
        return "\(formatted) ₫"
    }

    private func formatUSD(_ amount: Double) -> String {
        if amount <= 0 { return "$0.0000" }
        if amount < 0.01 { return String(format: "$%.6f", amount) }
        return String(format: "$%.4f", amount)
    }

    private func formatPriceUSD(_ pricePerMillion: Double) -> String {
        if pricePerMillion < 0.1 {
            return String(format: "$%.4f", pricePerMillion)
        }
        return String(format: "$%.2f", pricePerMillion)
    }
}
