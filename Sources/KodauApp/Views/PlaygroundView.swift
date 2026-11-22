import SwiftUI
import AppKit
import KodauCore

/// Home tab: type without diacritics, get the restored Vietnamese back, and teach individual words.
/// Works entirely inside the app window — no input source or Accessibility permission needed.
public struct PlaygroundView: View {
    @EnvironmentObject private var appState: AppState

    private enum PlaygroundMode: CaseIterable, Identifiable {
        case smart
        case vni

        var id: Self { self }

        var label: String {
            switch self {
            case .smart: return "Thông minh"
            case .vni: return "VNI"
            }
        }
    }

    private struct Sample: Identifiable {
        let id = UUID()
        let text: String
    }

    private let samples: [Sample] = [
        Sample(text: "hom nay toi di lam va review code Swift"),
        Sample(text: "meeting luc 3pm nhe, nho gui report cho team"),
        Sample(text: "toi muon xay dung bo go tieng viet khong dau"),
        Sample(text: "ban5 co the gui file design cho minh khong")
    ]

    @State private var playgroundMode: PlaygroundMode = .smart
    @State private var inputText: String = ""
    @State private var result: ConversionResult? = nil
    @State private var isConverting: Bool = false
    @State private var useGeminiIfAvailable: Bool = true

    @State private var selectedWordIndex: Int? = nil
    @State private var customCorrectionInput: String = ""
    @State private var enableVNIInCorrection: Bool = true
    @State private var correctionFeedback: String? = nil

    public init() {}

    public var body: some View {
        PageScaffold("Gõ thử", subtitle: "Gõ không dấu, Kodau thêm dấu ngay trong cửa sổ này.") {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.md) {
                    editorCard
                    if let result {
                        resultCard(result)
                        if let idx = selectedWordIndex, idx < words(of: result.convertedText).count {
                            correctionPanel(result, wordIndex: idx)
                        }
                    }
                }
                .padding(.horizontal, Space.lg)
                .padding(.bottom, Space.lg)
            }
        }
    }

    // MARK: - Editor

    private var editorCard: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                Picker("Chế độ", selection: $playgroundMode) {
                    ForEach(PlaygroundMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                .onChange(of: playgroundMode) { _, _ in
                    selectedWordIndex = nil
                    if !trimmedInput.isEmpty {
                        runConversion(allowCloud: false)
                    }
                }

                Spacer(minLength: Space.xs)

                if playgroundMode == .smart {
                    Toggle("Dùng Gemini khi cần", isOn: $useGeminiIfAvailable)
                        .toggleStyle(.checkbox)
                        .font(Typography.caption)
                        .disabled(!appState.config.hasAPIKey || appState.config.brainStrategy == .offlineOnly)
                        .help("Chỉ gọi Gemini khi bộ nhớ offline chưa đủ chắc.")
                }
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $inputText)
                    .font(.system(size: 15))
                    .scrollContentBackground(.hidden)
                    .padding(Space.xs)
                    .frame(minHeight: 120, maxHeight: 200)
                    .onChange(of: inputText) { oldVal, newVal in
                        if newVal.count > oldVal.count, let last = newVal.last, last == " " || last == "\n" {
                            runConversion(allowCloud: false)
                        }
                    }

                if inputText.isEmpty {
                    Text(playgroundMode == .smart
                         ? "hom nay toi hop team ve ke hoach moi"
                         : "hom6 nay toi6 hop5 team ve6 ke61 hoach5")
                        .font(.system(size: 15))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, Space.sm + 2)
                        .padding(.vertical, Space.sm + 2)
                        .allowsHitTesting(false)
                }
            }
            .background(
                Color(nsColor: .textBackgroundColor),
                in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )

            HStack(spacing: Space.sm) {
                Button {
                    runConversion(allowCloud: useGeminiIfAvailable)
                } label: {
                    HStack(spacing: Space.xxs + 2) {
                        if isConverting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text(isConverting ? "Đang xử lý…" : "Thêm dấu")
                    }
                    .frame(minWidth: 96)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isConverting || trimmedInput.isEmpty)

                Button("Chỉ chạy offline") {
                    runConversion(allowCloud: false)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isConverting || trimmedInput.isEmpty)
                .help("Không gọi Gemini, dùng bộ nhớ cục bộ (<1ms).")

                Spacer(minLength: Space.xs)

                if !inputText.isEmpty {
                    Button("Xóa") {
                        inputText = ""
                        result = nil
                        selectedWordIndex = nil
                        correctionFeedback = nil
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                } else if !appState.config.hasAPIKey && appState.config.brainStrategy != .offlineOnly {
                    Button("Thêm Gemini API Key") {
                        appState.selectedTab = .settings
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            }

            sampleRow
        }
        .kodauCard()
    }

    private var sampleRow: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Câu mẫu")
                .font(Typography.caption)
                .foregroundStyle(.secondary)

            FlowLayout(spacing: Space.xs) {
                ForEach(samples) { sample in
                    Button {
                        playgroundMode = .smart
                        inputText = sample.text
                        selectedWordIndex = nil
                        correctionFeedback = nil
                        runConversion(allowCloud: useGeminiIfAvailable)
                    } label: {
                        Text(sample.text)
                            .font(Typography.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, Space.xs)
                            .padding(.vertical, 5)
                            .background(
                                Color.primary.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Dùng câu mẫu này")
                }
            }
        }
    }

    // MARK: - Result

    private func resultCard(_ res: ConversionResult) -> some View {
        let words = words(of: res.convertedText)
        let changed = changedWordIndices(res)
        let altMap = Dictionary(uniqueKeysWithValues: res.alternatives.map { ($0.wordIndex, $0) })

        return VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.xs) {
                Text("Kết quả")
                    .font(Typography.section)

                Text(res.source.label)
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)

                Text("·")
                    .font(Typography.caption)
                    .foregroundStyle(.tertiary)

                Text(latencyLabel(res.latencyMs))
                    .font(Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                Text("·")
                    .font(Typography.caption)
                    .foregroundStyle(.tertiary)

                Text("\(Int((res.confidence * 100).rounded()))% tin cậy")
                    .font(Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                Spacer(minLength: Space.xs)

                if let feedback = correctionFeedback {
                    Text(feedback)
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(res.convertedText, forType: .string)
                } label: {
                    Label("Sao chép", systemImage: "doc.on.doc")
                        .font(Typography.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            FlowLayout(spacing: Space.xxs + 2) {
                ForEach(Array(words.enumerated()), id: \.offset) { idx, word in
                    wordChip(
                        word,
                        isChanged: changed.contains(idx),
                        hasAlternatives: (altMap[idx]?.candidates.count ?? 0) > 1,
                        isSelected: selectedWordIndex == idx
                    ) {
                        if selectedWordIndex == idx {
                            selectedWordIndex = nil
                        } else {
                            selectedWordIndex = idx
                            customCorrectionInput = word
                            correctionFeedback = nil
                        }
                    }
                }
            }
            .padding(.vertical, Space.xxs)

            Text("Bấm vào một từ để sửa dấu và dạy Kodau ghi nhớ.")
                .font(Typography.caption)
                .foregroundStyle(.tertiary)
        }
        .kodauCard()
    }

    private func wordChip(
        _ word: String,
        isChanged: Bool,
        hasAlternatives: Bool,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(word)
                    .font(.system(size: 16, weight: isChanged ? .medium : .regular))
                if hasAlternatives && !isSelected {
                    Circle()
                        .fill(Color.secondary.opacity(0.5))
                        .frame(width: 4, height: 4)
                }
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                chipBackground(isChanged: isChanged, isSelected: isSelected),
                in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .help(hasAlternatives ? "Có gợi ý khác cho từ này" : "Sửa dấu cho từ này")
    }

    private func chipBackground(isChanged: Bool, isSelected: Bool) -> AnyShapeStyle {
        if isSelected { return AnyShapeStyle(Color.accentColor) }
        if isChanged { return AnyShapeStyle(Color.accentColor.opacity(0.12)) }
        return AnyShapeStyle(Color.clear)
    }

    // MARK: - Inline word correction

    private func correctionPanel(_ res: ConversionResult, wordIndex idx: Int) -> some View {
        let outWords = words(of: res.convertedText)
        let currentWord = outWords[idx]
        let alt = res.alternatives.first { $0.wordIndex == idx }
        let rawWords = words(of: res.originalText)
        let rawWord = idx < rawWords.count ? rawWords[idx] : VNIEngine.stripDiacritics(currentWord)
        let quickCandidates = buildQuickCandidates(rawWord: rawWord, currentWord: currentWord, alt: alt)

        return VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.xs) {
                Text("Sửa từ “\(currentWord)”")
                    .font(Typography.section)

                Text("gốc: \(rawWord)")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: Space.xs)

                Button("Đóng") {
                    selectedWordIndex = nil
                }
                .buttonStyle(.borderless)
                .font(Typography.caption)
                .foregroundStyle(.secondary)
            }

            if !quickCandidates.isEmpty {
                FlowLayout(spacing: Space.xs) {
                    Text("Gợi ý")
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)

                    ForEach(quickCandidates, id: \.self) { candidate in
                        Button(candidate) {
                            applyWordCorrection(wordIndex: idx, chosenWord: candidate)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            HStack(spacing: Space.xs) {
                TextField("Nhập từ đúng (hỗ trợ VNI, vd: ba5n)", text: $customCorrectionInput)
                    .textFieldStyle(.roundedBorder)
                    .font(Typography.body)
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
                        teachWord(at: idx)
                    }

                Toggle("VNI", isOn: $enableVNIInCorrection)
                    .toggleStyle(.checkbox)
                    .font(Typography.caption)

                Button {
                    teachWord(at: idx)
                } label: {
                    Text("Dạy Kodau")
                }
                .buttonStyle(.borderedProminent)
                .disabled(customCorrectionInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .kodauCard()
    }

    // MARK: - Helpers

    private var trimmedInput: String {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func words(of text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Indices whose surface form differs from what the user typed (case-insensitive, ignoring punctuation).
    private func changedWordIndices(_ res: ConversionResult) -> Set<Int> {
        let rawWords = words(of: res.originalText)
        let outWords = words(of: res.convertedText)
        var indices = Set<Int>()
        for idx in outWords.indices {
            guard idx < rawWords.count else {
                indices.insert(idx)
                continue
            }
            if rawWords[idx].lowercased() != outWords[idx].lowercased() {
                indices.insert(idx)
            }
        }
        return indices
    }

    private func latencyLabel(_ ms: Double) -> String {
        ms < 1.0 ? "<1ms" : String(format: "%.0fms", ms)
    }

    private func buildQuickCandidates(rawWord: String, currentWord: String, alt: WordAlternative?) -> [String] {
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

    private func teachWord(at idx: Int) {
        let trimmed = customCorrectionInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        applyWordCorrection(wordIndex: idx, chosenWord: trimmed)
    }

    // MARK: - Logic

    private func runConversion(allowCloud: Bool) {
        let trimmed = trimmedInput
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
            let vniResult = ConversionResult(
                originalText: trimmed,
                convertedText: convertedTokens.joined(separator: " "),
                confidence: 1.0,
                source: .vniOverride,
                vietnameseRatio: 1.0,
                alternatives: [],
                latencyMs: elapsed
            )
            result = vniResult
            appState.lastConversion = vniResult
            appState.refreshStats()
            return
        }

        // Smart Mode
        if !allowCloud || appState.config.brainStrategy == .offlineOnly || !appState.config.hasAPIKey {
            let local = appState.coordinator.convertSync(trimmed, precedingContext: "")
            result = local
            appState.lastConversion = local
            appState.refreshStats()
            return
        }

        isConverting = true
        Task {
            let smart = await appState.coordinator.convertSmart(trimmed, precedingContext: "")
            await MainActor.run {
                result = smart
                isConverting = false
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

        result = updatedResult
        appState.lastConversion = updatedResult
        selectedWordIndex = nil
        correctionFeedback = "Đã học “\(chosenWord)”"
        appState.refreshStats()
    }
}
