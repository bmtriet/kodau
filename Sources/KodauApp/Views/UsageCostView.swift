import SwiftUI
import KodauCore

/// Token & VND Cost Statistics view (Day / Week / Month / Year / All Time)
/// with live Gemini API model pricing catalog and exchange rate configuration.
public struct UsageCostView: View {
    @EnvironmentObject private var appState: AppState

    @State private var selectedPeriod: UsagePeriod = .day
    @State private var breakdownBuckets: [UsageBreakdownBucket] = []
    @State private var exchangeRateInput: String = ""
    @State private var exchangeRateFeedback: String? = nil
    @State private var showResetConfirm: Bool = false

    private let overviewPeriods: [UsagePeriod] = [.day, .week, .month, .year]

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerRow

                // Today's Gemini quota (calls & VND) vs. the daily limits from Settings
                dailyQuotaCard

                // Period Segmented Selector
                Picker("Kỳ thống kê", selection: $selectedPeriod) {
                    ForEach(UsagePeriod.allCases) { period in
                        Text(period.title).tag(period)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                // Top 4 KPI Summary Cards
                kpiSummaryGrid

                // 4-Period Quick Overview Strip (Hôm nay · Tuần này · Tháng này · Năm nay)
                fourPeriodOverviewStrip

                // Breakdown Bar List
                breakdownSection

                // Gemini Model Pricing Table (USD & VND)
                modelPricingCatalogSection

                // Exchange Rate & Maintenance Controls
                exchangeRateAndControlsSection
            }
            .padding(24)
        }
        .onAppear {
            syncExchangeRateField()
            reloadUsageData()
        }
        .onChange(of: selectedPeriod) { _, _ in
            reloadBreakdown()
        }
        .onChange(of: appState.usageSummaries) { _, _ in
            // Summaries refresh live when KodauIM records new Gemini usage; keep the breakdown in sync.
            reloadBreakdown()
        }
        .onChange(of: appState.config.usdToVndRate) { _, _ in
            syncExchangeRateField()
            reloadUsageData()
        }
        .alert("Đặt lại thống kê Token & Chi phí API?", isPresented: $showResetConfirm) {
            Button("Hủy", role: .cancel) {}
            Button("Đặt lại về 0", role: .destructive) {
                appState.store.resetAPIUsage()
                reloadUsageData()
            }
        } message: {
            Text("Toàn bộ lịch sử token và chi phí ước tính của Gemini API sẽ bị xóa về 0. Từ điển đã học và API Key vẫn được giữ nguyên.")
        }
    }

    // MARK: - Current Data Helpers

    private var activeSummary: UsageSummary {
        if let cached = appState.usageSummaries.first(where: { $0.period == selectedPeriod }) {
            return cached
        }
        return appState.store.fetchUsageSummary(
            period: selectedPeriod,
            usdToVndRate: appState.config.usdToVndRate
        )
    }

    private func summary(for period: UsagePeriod) -> UsageSummary {
        if let cached = appState.usageSummaries.first(where: { $0.period == period }) {
            return cached
        }
        return appState.store.fetchUsageSummary(
            period: period,
            usdToVndRate: appState.config.usdToVndRate
        )
    }

    private var activePricing: GeminiModelPricing {
        GeminiModelPricing.pricing(for: appState.config.geminiModel)
    }

    private var currentRate: Double {
        max(1_000, appState.config.usdToVndRate)
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Thống kê Token & Chi phí Gemini API")
                    .font(.title2.bold())
                Text("Theo dõi lượng token đã tiêu thụ và chi phí ước tính theo tỷ giá \(formatVND(currentRate))/USD.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                reloadUsageData()
            } label: {
                Label("Làm mới", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - Daily Quota

    private var dailyQuotaCard: some View {
        let today = summary(for: .day)
        let callLimit = appState.config.dailyGeminiCallLimit
        let budget = appState.config.dailyGeminiBudgetVND
        let callsExhausted = callLimit > 0 && today.apiCalls >= callLimit
        let budgetExhausted = budget > 0 && today.costVND >= budget
        let exhausted = callsExhausted || budgetExhausted

        return cardContainer(title: "Hạn mức Gemini hôm nay", icon: "gauge.with.dots.needle.67percent") {
            VStack(alignment: .leading, spacing: 12) {
                if exhausted {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(callsExhausted
                             ? "Đã dùng hết \(formatInt(callLimit)) lượt gọi hôm nay. Kodau đang chạy 100% offline đến hết ngày (vẫn thêm dấu bình thường)."
                             : "Đã chạm ngân sách \(formatVND(budget)) hôm nay. Kodau đang chạy 100% offline đến hết ngày (vẫn thêm dấu bình thường).")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                HStack(alignment: .top, spacing: 24) {
                    quotaMeter(
                        label: "Lượt gọi",
                        valueText: "\(formatInt(today.apiCalls)) / \(callLimit > 0 ? formatInt(callLimit) : "∞")",
                        fraction: callLimit > 0 ? Double(today.apiCalls) / Double(callLimit) : nil
                    )
                    quotaMeter(
                        label: "Chi phí ước tính",
                        valueText: "\(formatVND(today.costVND)) / \(budget > 0 ? formatVND(budget) : "∞")",
                        fraction: budget > 0 ? today.costVND / budget : nil
                    )
                }

                Text("Chỉnh hạn mức trong Cài đặt → Giới hạn gọi Gemini mỗi ngày. Số liệu gộp cả Kodau.app và bộ gõ KodauIM.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func quotaMeter(label: String, valueText: String, fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(valueText)
                    .font(.caption.monospaced().weight(.semibold))
            }
            if let fraction {
                let clamped = min(1.0, max(0.0, fraction))
                ProgressView(value: clamped)
                    .tint(clamped >= 1.0 ? .orange : (clamped >= 0.8 ? .yellow : .accentColor))
            } else {
                Text("Không giới hạn")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Top 4 KPI Summary Cards

    private var kpiSummaryGrid: some View {
        let s = activeSummary
        let avgTokens = s.apiCalls > 0 ? Int((Double(s.totalTokens) / Double(s.apiCalls)).rounded()) : 0
        let inputVNDPerM = activePricing.inputPerMillionUSD * currentRate
        let outputVNDPerM = activePricing.outputPerMillionUSD * currentRate

        return LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 14),
                GridItem(.flexible(), spacing: 14)
            ],
            spacing: 14
        ) {
            // 1. Estimated Cost (VND)
            kpiCard(
                title: "Chi phí ước tính (\(selectedPeriod.title))",
                icon: "dongsign.circle.fill",
                tint: .green
            ) {
                Text(formatVND(s.costVND))
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Text(formatUSD(s.costUSD))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text("Nếu dùng Free Tier AI Studio thì chi phí thực tế là 0 ₫")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .padding(.top, 2)
            }

            // 2. Total Tokens
            kpiCard(
                title: "Tổng Tokens (\(selectedPeriod.title))",
                icon: "text.word.spacing",
                tint: .blue
            ) {
                Text("\(formatInt(s.totalTokens)) tokens")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Text("In: \(formatInt(s.promptTokens)) · Out: \(formatInt(s.outputTokens))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text("Chỉ tính các câu cần gọi Gemini API (Offline = 0 token)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }

            // 3. Gemini API Calls
            kpiCard(
                title: "Số lượt gọi Gemini API",
                icon: "bolt.horizontal.circle.fill",
                tint: .purple
            ) {
                Text("\(formatInt(s.apiCalls)) lượt")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Text("Trung bình: \(formatInt(avgTokens)) tokens/lượt")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(s.apiCalls == 0 ? "Chưa có lượt gọi API nào trong kỳ này" : "Dữ liệu đã được đồng bộ từ cả Kodau & KodauIM")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }

            // 4. Active Model & Unit Price
            kpiCard(
                title: "Model đang dùng",
                icon: "sparkles",
                tint: .orange
            ) {
                Text(appState.config.geminiModel)
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text("In: \(formatPriceUSD(activePricing.inputPerMillionUSD))/1M (\(formatVND(inputVNDPerM)))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text("Out: \(formatPriceUSD(activePricing.outputPerMillionUSD))/1M (\(formatVND(outputVNDPerM)))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func kpiCard<Content: View>(
        title: String,
        icon: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - 4-Period Quick Overview Strip

    private var fourPeriodOverviewStrip: some View {
        cardContainer(title: "Tổng quan nhanh theo thời gian", icon: "calendar") {
            HStack(spacing: 12) {
                ForEach(overviewPeriods) { period in
                    let s = summary(for: period)
                    let isSelected = selectedPeriod == period
                    Button {
                        selectedPeriod = period
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(period.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                                Spacer()
                                if isSelected {
                                    Circle()
                                        .fill(Color.accentColor)
                                        .frame(width: 6, height: 6)
                                }
                            }

                            Text(formatVND(s.costVND))
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(.primary)

                            Text("\(formatInt(s.totalTokens)) tokens")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)

                            Text("\(formatInt(s.apiCalls)) lượt gọi")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            isSelected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.03),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(
                                    isSelected ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.06),
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Breakdown Bar List

    private var breakdownSection: some View {
        let maxTokens = max(1, breakdownBuckets.map(\.totalTokens).max() ?? 1)

        return cardContainer(
            title: "Chi tiết tiêu thụ — \(selectedPeriod.title)",
            icon: "chart.bar.xaxis"
        ) {
            if breakdownBuckets.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "chart.bar.doc.horizontal")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Chưa có dữ liệu gọi Gemini API trong kỳ \"\(selectedPeriod.title)\"")
                            .font(.subheadline.weight(.medium))
                        Text("Khi Kodau gọi Gemini API (hoặc khi bạn bấm \"Kiểm tra kết nối API\"), lượng token và chi phí VND sẽ xuất hiện tại đây.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 8) {
                    ForEach(breakdownBuckets) { bucket in
                        let ratio = min(1.0, max(0.02, Double(bucket.totalTokens) / Double(maxTokens)))
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 10) {
                                Text(bucket.label)
                                    .font(.caption.monospaced().weight(.semibold))
                                    .frame(width: 110, alignment: .leading)

                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .fill(Color.primary.opacity(0.06))
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .fill(
                                                LinearGradient(
                                                    colors: [.blue, .indigo],
                                                    startPoint: .leading,
                                                    endPoint: .trailing
                                                )
                                            )
                                            .frame(width: max(4, geo.size.width * ratio))
                                    }
                                }
                                .frame(height: 10)

                                Text("\(formatInt(bucket.apiCalls)) lượt")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 62, alignment: .trailing)

                                Text("\(formatInt(bucket.totalTokens)) tok")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.primary)
                                    .frame(width: 86, alignment: .trailing)

                                Text(formatVND(bucket.costVND))
                                    .font(.caption.monospaced().weight(.semibold))
                                    .foregroundStyle(.green)
                                    .frame(width: 82, alignment: .trailing)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
    }

    // MARK: - Gemini Model Pricing Catalog

    private var modelPricingCatalogSection: some View {
        let activeLower = appState.config.geminiModel.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        return cardContainer(
            title: "Bảng giá các Model Gemini (Quy đổi VND)",
            icon: "tablecells"
        ) {
            VStack(spacing: 8) {
                // Header row
                HStack(spacing: 10) {
                    Text("Model")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Input / 1M")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 120, alignment: .trailing)
                    Text("Output / 1M")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 120, alignment: .trailing)
                    Text("Thao tác")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 88, alignment: .trailing)
                }
                .padding(.horizontal, 10)

                Divider()

                ForEach(GeminiModelPricing.catalog) { item in
                    let isCurrent = item.modelID.lowercased() == activeLower
                    let inVND = item.inputPerMillionUSD * currentRate
                    let outVND = item.outputPerMillionUSD * currentRate

                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(item.displayName)
                                    .font(.subheadline.weight(.semibold))
                                Text(item.modelID)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                if isCurrent {
                                    Text("Đang dùng")
                                        .font(.caption2.weight(.bold))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(Color.green.opacity(0.16), in: Capsule())
                                        .foregroundStyle(.green)
                                }
                            }
                            if !item.note.isEmpty {
                                Text(item.note)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(alignment: .trailing, spacing: 1) {
                            Text(formatPriceUSD(item.inputPerMillionUSD))
                                .font(.caption.monospaced().weight(.semibold))
                            Text(formatVND(inVND))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 120, alignment: .trailing)

                        VStack(alignment: .trailing, spacing: 1) {
                            Text(formatPriceUSD(item.outputPerMillionUSD))
                                .font(.caption.monospaced().weight(.semibold))
                            Text(formatVND(outVND))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 120, alignment: .trailing)

                        Group {
                            if isCurrent {
                                Label("Đang dùng", systemImage: "checkmark.circle.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.green)
                            } else {
                                Button("Chọn") {
                                    appState.config.geminiModel = item.modelID
                                    appState.saveConfig()
                                    reloadUsageData()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                        .frame(width: 88, alignment: .trailing)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        isCurrent ? Color.green.opacity(0.07) : Color.primary.opacity(0.025),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(isCurrent ? Color.green.opacity(0.30) : Color.clear, lineWidth: 1)
                    )
                }
            }
        }
    }

    // MARK: - Exchange Rate & Reset Controls

    private var exchangeRateAndControlsSection: some View {
        cardContainer(title: "Tỷ giá USD → VND & Quản lý thống kê", icon: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Text("Tỷ giá 1 USD =")
                        .font(.subheadline.weight(.medium))

                    TextField("25800", text: $exchangeRateInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 130)
                        .onSubmit {
                            applyExchangeRate()
                        }

                    Text("₫")
                        .font(.subheadline.weight(.semibold))

                    Button("Lưu tỷ giá") {
                        applyExchangeRate()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button("Mặc định (25.800 ₫)") {
                        appState.config.usdToVndRate = 25_800
                        appState.saveConfig()
                        syncExchangeRateField()
                        exchangeRateFeedback = "Đã đặt lại tỷ giá mặc định 25.800 ₫/USD."
                        reloadUsageData()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Spacer()
                }

                if let feedback = exchangeRateFeedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Đặt lại thống kê API")
                            .font(.subheadline.weight(.semibold))
                        Text("Xóa toàn bộ bộ đếm token và chi phí VND đã ghi nhận (không ảnh hưởng từ điển đã học).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        reloadUsageData()
                    } label: {
                        Label("Làm mới", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive) {
                        showResetConfirm = true
                    } label: {
                        Label("Đặt lại thống kê API", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }
        }
    }

    // MARK: - Card Container & Actions

    @ViewBuilder
    private func cardContainer<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
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
            exchangeRateFeedback = "Vui lòng nhập tỷ giá hợp lệ (từ 1.000 đến 200.000 ₫/USD)."
            return
        }
        appState.config.usdToVndRate = parsed
        appState.saveConfig()
        exchangeRateFeedback = "Đã cập nhật tỷ giá \(formatVND(parsed))/USD."
        reloadUsageData()
    }

    // MARK: - Formatting Helpers

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
        if amount <= 0 {
            return "0 ₫"
        }
        if amount < 1.0 {
            return String(format: "%.2f ₫", amount).replacingOccurrences(of: ".", with: ",")
        }
        let rounded = Int(amount.rounded())
        let formatted = Self.intFormatter.string(from: NSNumber(value: rounded)) ?? "\(rounded)"
        return "\(formatted) ₫"
    }

    private func formatUSD(_ amount: Double) -> String {
        if amount <= 0 {
            return "$0.0000 USD"
        }
        if amount < 0.01 {
            return String(format: "$%.6f USD", amount)
        }
        return String(format: "$%.4f USD", amount)
    }

    private func formatPriceUSD(_ pricePerMillion: Double) -> String {
        if pricePerMillion < 0.1 {
            return String(format: "$%.4f", pricePerMillion)
        }
        return String(format: "$%.2f", pricePerMillion)
    }
}
