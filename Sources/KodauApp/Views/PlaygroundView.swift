import SwiftUI
import AppKit
import KodauCore

/// Interactive Playground & AI Teaching Studio.
/// Works 100% inside the app window — even before macOS Accessibility permission is granted.
public struct PlaygroundView: View {
    @EnvironmentObject private var appState: AppState

    private enum PlaygroundMode: String, CaseIterable, Identifiable {
        case smart = "Thông minh (Không dấu + Anh)"
        case vni = "Gõ VNI thủ công"
        var id: String { rawValue }
    }

    private struct SampleItem: Identifiable {
        let id = UUID()
        let label: String
        let text: String
    }

    private let samples: [SampleItem] = [
        SampleItem(label: "Công việc + Code", text: "hom nay toi di lam va review code Swift"),
        SampleItem(label: "Chat Team + Tiếng Anh", text: "meeting luc 3pm nhe, nho gui report cho team"),
        SampleItem(label: "Tiếng Việt thuần", text: "toi muon xay dung bo go tieng viet khong dau"),
        SampleItem(label: "Kèm VNI nhanh", text: "ban5 co the gui file design cho minh khong")
    ]

    @State private var playgroundMode: PlaygroundMode = .smart
    @State private var inputText: String = ""
    @State private var result: ConversionResult? = nil
    @State private var isConverting: Bool = false
    @State private var useGeminiIfAvailable: Bool = true

    // Word correction popover/panel state
    @State private var selectedWordIndex: Int? = nil
    @State private var customCorrectionInput: String = ""
    @State private var enableVNIInCorrection: Bool = true
    @State private var correctionFeedback: String? = nil

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerSection
                sampleButtonsBar
                inputCard
                if let result {
                    outputCard(result)
                    interactiveWordCorrectionCard(result)
                }
            }
            .padding(24)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Thử nghiệm & Dạy AI")
                    .font(.title2.bold())
                Text("Gõ tiếng Việt không dấu xen kẽ tiếng Anh (hoặc VNI) ngay tại đây — hoạt động tức thì kể cả khi chưa bật Quyền Trợ năng.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("Chế độ thử", selection: $playgroundMode) {
                ForEach(PlaygroundMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 340)
            .onChange(of: playgroundMode) { _, _ in
                selectedWordIndex = nil
                if !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    runConversion(allowCloud: false)
                }
            }
        }
    }

    // MARK: - Quick Samples

    private var sampleButtonsBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Câu mẫu thử nhanh:")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(samples) { sample in
                        Button {
                            playgroundMode = .smart
                            inputText = sample.text
                            selectedWordIndex = nil
                            correctionFeedback = nil
                            runConversion(allowCloud: useGeminiIfAvailable)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "text.bubble")
                                    .font(.caption)
                                Text(sample.text)
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Input Card

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(
                    playgroundMode == .smart
                        ? "Nhập câu không dấu + tiếng Anh"
                        : "Nhập chuỗi VNI (vd: hom6 nay toi6 d9i lam2)",
                    systemImage: "keyboard"
                )
                .font(.headline)

                Spacer()

                if playgroundMode == .smart {
                    Toggle("Dùng Gemini nếu cục bộ chưa chắc", isOn: $useGeminiIfAvailable)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .disabled(!appState.config.hasAPIKey || appState.config.brainStrategy == .offlineOnly)
                }
            }

            TextEditor(text: $inputText)
                .font(.system(size: 15))
                .frame(minHeight: 82, maxHeight: 130)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                )
                .onChange(of: inputText) { oldVal, newVal in
                    // Trigger fast instant local preview on Space or Return
                    if newVal.count > oldVal.count, let last = newVal.last, last == " " || last == "\n" {
                        runConversion(allowCloud: false)
                    }
                }

            HStack(spacing: 10) {
                Button {
                    runConversion(allowCloud: useGeminiIfAvailable)
                } label: {
                    HStack(spacing: 6) {
                        if isConverting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text(isConverting ? "Đang phân tích..." : "Chuyển đổi ngay")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isConverting || inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Chỉ chạy Offline (<1ms)") {
                    runConversion(allowCloud: false)
                }
                .buttonStyle(.bordered)
                .disabled(isConverting || inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if !inputText.isEmpty {
                    Button("Xóa") {
                        inputText = ""
                        result = nil
                        selectedWordIndex = nil
                        correctionFeedback = nil
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if !appState.config.hasAPIKey && appState.config.brainStrategy != .offlineOnly {
                    Button {
                        appState.showAPIKeyDialog = true
                    } label: {
                        Label("Nhập Gemini API Key để học nhanh hơn", systemImage: "key.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Output Card

    private func outputCard(_ res: ConversionResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label("Kết quả phục hồi dấu", systemImage: "checkmark.bubble.fill")
                    .font(.headline)

                // Engine badge
                engineBadge(source: res.source, latencyMs: res.latencyMs)

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(res.convertedText, forType: .string)
                } label: {
                    Label("Sao chép", systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text(res.convertedText)
                .font(.system(size: 18, weight: .medium))
                .textSelection(.enabled)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.20), lineWidth: 1)
                )

            // Confidence & Language Ratio Meters
            HStack(spacing: 20) {
                HStack(spacing: 8) {
                    Text("Độ tin cậy:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ProgressView(value: res.confidence)
                        .frame(width: 110)
                        .tint(res.confidence >= appState.config.localConfidenceThreshold ? .green : .orange)
                    Text("\(Int((res.confidence * 100).rounded()))%")
                        .font(.caption.monospaced().weight(.semibold))
                }

                HStack(spacing: 6) {
                    Text("Tỉ lệ tiếng Việt:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(Int((res.vietnameseRatio * 100).rounded()))%")
                        .font(.caption.monospaced().weight(.semibold))
                }

                HStack(spacing: 6) {
                    Text("Độ trễ:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.1f ms", res.latencyMs))
                        .font(.caption.monospaced().weight(.semibold))
                }

                Spacer()
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func engineBadge(source: ConversionSource, latencyMs: Double) -> some View {
        let color: Color = {
            switch source {
            case .geminiAPI: return .purple
            case .vniOverride: return .orange
            case .localEnglish, .passthrough: return .gray
            default: return .green
            }
        }()

        let labelText: String = {
            if source.isOffline && source != .vniOverride {
                let speed = latencyMs < 1.0 ? "<1ms" : String(format: "%.0fms", latencyMs)
                return "\(source.label) (\(speed))"
            }
            return source.label
        }()

        HStack(spacing: 4) {
            Image(systemName: source == .geminiAPI ? "sparkles" : "cpu")
                .font(.caption2)
            Text(labelText)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(color.opacity(0.15), in: Capsule())
        .foregroundStyle(color)
    }

    // MARK: - Interactive Word Chips & AI Teaching

    private func interactiveWordCorrectionCard(_ res: ConversionResult) -> some View {
        let words = res.convertedText.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let altMap: [Int: WordAlternative] = Dictionary(
            uniqueKeysWithValues: res.alternatives.map { ($0.wordIndex, $0) }
        )

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Nhấp vào bất kỳ từ nào để sửa dấu & dạy Kodau ghi nhớ", systemImage: "hand.tap.fill")
                    .font(.headline)
                Spacer()
                if let feedback = correctionFeedback {
                    Label(feedback, systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                }
            }

            // Wrapping word chips
            FlowChipLayout(spacing: 8) {
                ForEach(Array(words.enumerated()), id: \.offset) { idx, word in
                    let hasAlts = (altMap[idx]?.candidates.count ?? 0) > 1
                    let isSelected = (selectedWordIndex == idx)

                    Button {
                        if selectedWordIndex == idx {
                            selectedWordIndex = nil
                        } else {
                            selectedWordIndex = idx
                            customCorrectionInput = word
                            correctionFeedback = nil
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(word)
                                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                            if hasAlts {
                                Circle()
                                    .fill(isSelected ? Color.white : Color.orange)
                                    .frame(width: 5, height: 5)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            isSelected
                                ? AnyShapeStyle(Color.accentColor)
                                : AnyShapeStyle(Color.primary.opacity(hasAlts ? 0.10 : 0.05)),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .foregroundStyle(isSelected ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Active word correction panel
            if let idx = selectedWordIndex, idx < words.count {
                let currentWord = words[idx]
                let alt = altMap[idx]
                let rawWords = res.originalText.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                let rawWord = idx < rawWords.count ? rawWords[idx] : VNIEngine.stripDiacritics(currentWord)

                VStack(alignment: .leading, spacing: 10) {
                    Divider()

                    HStack {
                        Text("Dạy từ thứ #\(idx + 1):")
                            .font(.subheadline.weight(.semibold))
                        Text("\"\(rawWord)\" → \"\(currentWord)\"")
                            .font(.subheadline.monospaced())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Đóng") {
                            selectedWordIndex = nil
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    // Candidate quick buttons
                    let quickCandidates = buildQuickCandidates(rawWord: rawWord, currentWord: currentWord, alt: alt)
                    if !quickCandidates.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                Text("Gợi ý:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                ForEach(quickCandidates, id: \.self) { cand in
                                    Button(cand) {
                                        applyWordCorrection(wordIndex: idx, chosenWord: cand)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }

                    // Custom VNI-aware correction text field
                    HStack(spacing: 10) {
                        TextField("Nhập từ đúng (hỗ trợ gõ VNI như ba5n -> bạn)...", text: $customCorrectionInput)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: customCorrectionInput) { oldVal, newVal in
                                guard enableVNIInCorrection, newVal.count == oldVal.count + 1,
                                      let lastChar = newVal.last, lastChar.isNumber else { return }
                                let prefix = String(newVal.dropLast())
                                let vniRes = appState.coordinator.vniEngine.processKey(
                                    currentWord: prefix,
                                    key: lastChar
                                )
                                if vniRes.didTransform {
                                    customCorrectionInput = vniRes.newWord
                                }
                            }
                            .onSubmit {
                                let trimmed = customCorrectionInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !trimmed.isEmpty {
                                    applyWordCorrection(wordIndex: idx, chosenWord: trimmed)
                                }
                            }

                        Toggle("Gõ VNI", isOn: $enableVNIInCorrection)
                            .toggleStyle(.checkbox)
                            .font(.caption)

                        Button {
                            let trimmed = customCorrectionInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                applyWordCorrection(wordIndex: idx, chosenWord: trimmed)
                            }
                        } label: {
                            Label("Dạy Kodau", systemImage: "brain.head.profile")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(customCorrectionInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Logic

    private func buildQuickCandidates(
        rawWord: String,
        currentWord: String,
        alt: WordAlternative?
    ) -> [String] {
        var list: [String] = []
        if let alt {
            for cand in alt.candidates where !list.contains(cand) {
                list.append(cand)
            }
        }
        if !list.contains(rawWord) {
            list.append(rawWord)
        }
        return list.filter { $0 != currentWord }
    }

    private func runConversion(allowCloud: Bool) {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            result = nil
            return
        }

        if playgroundMode == .vni {
            let start = Date()
            let tokens = trimmed.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            var convertedTokens: [String] = []
            var context = ""
            for token in tokens {
                let (conv, _) = appState.coordinator.vniEngine.convertWord(token)
                convertedTokens.append(conv)
                if !conv.isEmpty {
                    appState.coordinator.learnFromVNIWord(conv, precedingContext: context)
                    context = (context.isEmpty ? conv : context + " " + conv)
                }
            }
            let elapsed = Date().timeIntervalSince(start) * 1000.0
            let convertedSentence = convertedTokens.joined(separator: " ")
            let vniResult = ConversionResult(
                originalText: trimmed,
                convertedText: convertedSentence,
                confidence: 1.0,
                source: .vniOverride,
                vietnameseRatio: 1.0,
                alternatives: [],
                latencyMs: elapsed
            )
            self.result = vniResult
            appState.lastConversion = vniResult
            appState.refreshStats()
            return
        }

        // Smart Mode
        if !allowCloud || appState.config.brainStrategy == .offlineOnly || !appState.config.hasAPIKey {
            let local = appState.coordinator.convertSync(trimmed, precedingContext: "")
            self.result = local
            appState.lastConversion = local
            appState.refreshStats()
            return
        }

        isConverting = true
        Task {
            let smart = await appState.coordinator.convertSmart(trimmed, precedingContext: "")
            await MainActor.run {
                self.result = smart
                self.isConverting = false
                appState.lastConversion = smart
                appState.refreshStats()
            }
        }
    }

    private func applyWordCorrection(wordIndex: Int, chosenWord: String) {
        guard let currentResult = result else { return }
        let updatedText = appState.coordinator.applyUserCorrection(
            rawClause: currentResult.originalText,
            currentConverted: currentResult.convertedText,
            wordIndex: wordIndex,
            chosenWord: chosenWord
        )

        let updatedResult = ConversionResult(
            originalText: currentResult.originalText,
            convertedText: updatedText,
            confidence: 1.0,
            source: .localExact,
            vietnameseRatio: currentResult.vietnameseRatio,
            alternatives: currentResult.alternatives,
            latencyMs: 0.2
        )

        self.result = updatedResult
        appState.lastConversion = updatedResult
        selectedWordIndex = nil
        correctionFeedback = "Đã học \"\(chosenWord)\" vào bộ nhớ Offline!"
        appState.refreshStats()
    }
}

/// Simple wrapping horizontal flow layout for word chips (macOS 14+ `Layout` protocol).
private struct FlowChipLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 600
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
