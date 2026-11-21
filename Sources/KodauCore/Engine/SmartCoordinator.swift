import Foundation

/// Why the last `convertSmart` call answered locally instead of reaching the Gemini API.
public enum GeminiSkipReason: Equatable, Sendable {
    /// An identical clause (same text + context tail + model) was answered earlier and cached.
    case cacheHit
    /// The offline brain already knows the clause (verified memory, near-certain / confident English).
    case knownLocally
    /// `AppConfig.dailyGeminiCallLimit` reached for today (shared across Kodau.app + KodauIM).
    case dailyCallLimit
    /// `AppConfig.dailyGeminiBudgetVND` reached for today (shared across Kodau.app + KodauIM).
    case dailyBudget
    /// Brain strategy is `.offlineOnly` or no API key is configured.
    case offline
}

/// Test hook replacing the real network round-trip; production code passes `nil` and uses `GeminiClient`.
internal typealias GeminiRestoreOverride = @Sendable (
    _ text: String,
    _ precedingContext: String,
    _ apiKey: String,
    _ model: String
) async throws -> ConversionResult

/// High-level coordinator orchestrating `LearningStore`, `LocalDiacriticEngine`,
/// `VNIEngine`, and `GeminiClient` according to `AppConfig.typingMode` and `AppConfig.brainStrategy`.
public final class SmartCoordinator: @unchecked Sendable {
    public let store: LearningStore
    public let localEngine: LocalDiacriticEngine
    public let geminiClient: GeminiClient

    private let stateLock = NSLock()
    private var _vniEngine: VNIEngine
    private var _config: AppConfig

    // Gemini call policy state, all guarded by `stateLock`.
    private var _lastGeminiSkipReason: GeminiSkipReason?
    private var _lastGeminiCallStartedAt: Date?
    private var _geminiRestoreOverride: GeminiRestoreOverride?
    private var geminiCache: [String: GeminiCacheEntry] = [:]
    private var geminiCacheOrder: [String] = []

    private static let geminiCacheCapacity = 200
    private static let geminiCacheTTL: TimeInterval = 30 * 60

    private struct GeminiCacheEntry {
        let text: String
        let confidence: Double
        let vietnameseRatio: Double
        let alternatives: [WordAlternative]
        let correctionGeneration: UInt64
        let storedAt: Date
    }

    /// Test-only replacement for the network call; production keeps this `nil` and uses `geminiClient`.
    internal var geminiRestoreOverride: GeminiRestoreOverride? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _geminiRestoreOverride
        }
        set {
            stateLock.lock()
            defer { stateLock.unlock() }
            _geminiRestoreOverride = newValue
        }
    }

    /// Reason the last `convertSmart` call stayed offline; `nil` after a real API call.
    public var lastGeminiSkipReason: GeminiSkipReason? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _lastGeminiSkipReason
    }

    public var vniEngine: VNIEngine {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _vniEngine
        }
        set {
            stateLock.lock()
            defer { stateLock.unlock() }
            _vniEngine = newValue
        }
    }

    public var config: AppConfig {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _config
        }
        set {
            stateLock.lock()
            defer { stateLock.unlock() }
            _config = newValue
            _vniEngine = VNIEngine(modernTonePlacement: newValue.modernTonePlacement)
        }
    }

    public init(
        store: LearningStore,
        config: AppConfig = AppConfig.load(),
        geminiClient: GeminiClient = GeminiClient()
    ) {
        self.store = store
        self.localEngine = LocalDiacriticEngine(store: store)
        self.geminiClient = geminiClient
        self._config = config
        self._vniEngine = VNIEngine(modernTonePlacement: config.modernTonePlacement)
    }

    /// Updates active config (also updates `vniEngine` tone placement).
    public func updateConfig(_ newConfig: AppConfig) {
        stateLock.lock()
        _config = newConfig
        _vniEngine = VNIEngine(modernTonePlacement: newConfig.modernTonePlacement)
        stateLock.unlock()
    }

    /// Fast synchronous local-only conversion (ideal for instant on-Space response <1ms).
    ///
    /// `forceSmartEngine` lets `⌥Space` ask the Smart engine to restore diacritics from plain ASCII while the
    /// user is typing in VNI mode. It only overrides `.vni`; `.english` stays a strict pass-through.
    public func convertSync(
        _ text: String,
        precedingContext: String = "",
        forceSmartEngine: Bool = false
    ) -> ConversionResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        let elapsedMs: () -> Double = { (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0 }

        let (cfg, vni) = snapshotState()
        let mode = effectiveTypingMode(cfg, forceSmartEngine: forceSmartEngine)

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ConversionResult(
                originalText: text,
                convertedText: text,
                confidence: 1.0,
                source: .passthrough,
                vietnameseRatio: 0.0,
                alternatives: [],
                latencyMs: elapsedMs()
            )
        }

        if mode == .english {
            return ConversionResult(
                originalText: text,
                convertedText: text,
                confidence: 1.0,
                source: .passthrough,
                vietnameseRatio: 0.0,
                alternatives: [],
                latencyMs: elapsedMs()
            )
        }

        if mode == .vni {
            let vniPass = convertAllVNITokens(text, using: vni)
            return ConversionResult(
                originalText: text,
                convertedText: vniPass.output,
                confidence: 1.0,
                source: vniPass.didConvertAny ? .vniOverride : .passthrough,
                vietnameseRatio: vniPass.didConvertAny ? 1.0 : 0.0,
                alternatives: [],
                latencyMs: elapsedMs()
            )
        }

        // Smart Mode: check inline VNI tokens first if enabled
        var workingText = text
        if cfg.inlineVNIOverrideEnabled {
            let inlinePass = applyInlineVNIOverrides(text, using: vni)
            workingText = inlinePass.output
            if inlinePass.allWordsConverted && inlinePass.convertedCount > 0 {
                return ConversionResult(
                    originalText: text,
                    convertedText: workingText,
                    confidence: 1.0,
                    source: .vniOverride,
                    vietnameseRatio: 1.0,
                    alternatives: [],
                    latencyMs: elapsedMs()
                )
            }
        }

        let localResult = localEngine.convert(workingText, precedingContext: precedingContext)
        let normalizedText = VNIEngine.normalizeOaOeUyToneStyle(
            localResult.convertedText,
            preferFirstVowel: cfg.modernTonePlacement
        )
        let normalizedAlternatives = normalizeAlternatives(
            localResult.alternatives,
            preferFirstVowel: cfg.modernTonePlacement
        )

        return ConversionResult(
            originalText: text,
            convertedText: normalizedText,
            confidence: localResult.confidence,
            source: localResult.source,
            vietnameseRatio: localResult.vietnameseRatio,
            alternatives: normalizedAlternatives,
            latencyMs: workingText == text ? localResult.latencyMs : elapsedMs()
        )
    }

    /// Full smart conversion respecting `config.typingMode` and `config.brainStrategy`:
    /// 1. If mode == .english -> passthrough.
    /// 2. Checks inline VNI tokens if `config.inlineVNIOverrideEnabled` (converts them via VNIEngine and teaches LearningStore with userVerified=true!).
    /// 3. Runs LocalDiacriticEngine first.
    /// 4. If strategy == .offlineOnly OR !config.hasAPIKey -> uses local result, logs telemetry, returns.
    /// 5. If the brain already knows the clause (phrase memory, user-verified context, near-certain local
    ///    answer, confident pure English) OR (Hybrid) localResult.confidence >= config.localConfidenceThreshold
    ///    -> uses local result (0 API calls!), logs telemetry, returns.
    /// 6. If an identical clause was already answered by Gemini (same context tail + model, brain unchanged)
    ///    -> serves the cached answer without any network, usage, or re-learning.
    /// 7. If today's call count / estimated spend reached `dailyGeminiCallLimit` / `dailyGeminiBudgetVND`
    ///    (read from the shared `api_usage` table) -> uses local result, records the skip reason, returns.
    /// 8. Waits out `minGeminiIntervalSeconds` since the previous call; cancellation during that wait keeps
    ///    the request offline.
    /// 9. Otherwise calls GeminiClient in a detached task (so an in-flight request is never cancelled by a
    ///    newer keystroke). On success: records usage, distills & learns the result, caches it, logs telemetry,
    ///    returns. On failure: gracefully falls back to localResult!
    public func convertSmart(
        _ text: String,
        precedingContext: String = "",
        forceSmartEngine: Bool = false
    ) async -> ConversionResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        let elapsedMs: () -> Double = { (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0 }

        let (cfg, vni) = snapshotState()
        let mode = effectiveTypingMode(cfg, forceSmartEngine: forceSmartEngine)

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ConversionResult(
                originalText: text,
                convertedText: text,
                confidence: 1.0,
                source: .passthrough,
                vietnameseRatio: 0.0,
                alternatives: [],
                latencyMs: elapsedMs()
            )
        }

        // 1. English mode -> passthrough
        if mode == .english {
            return ConversionResult(
                originalText: text,
                convertedText: text,
                confidence: 1.0,
                source: .passthrough,
                vietnameseRatio: 0.0,
                alternatives: [],
                latencyMs: elapsedMs()
            )
        }

        // Pure VNI mode
        if mode == .vni {
            let vniPass = convertAllVNITokens(text, using: vni)
            if vniPass.didConvertAny {
                if cfg.learnFromVNIMode {
                    store.learnFromText(vniPass.output, source: "vni", userVerified: true)
                }
                store.recordConversionEvent(source: .vniOverride)
            }
            return ConversionResult(
                originalText: text,
                convertedText: vniPass.output,
                confidence: 1.0,
                source: vniPass.didConvertAny ? .vniOverride : .passthrough,
                vietnameseRatio: vniPass.didConvertAny ? 1.0 : 0.0,
                alternatives: [],
                latencyMs: elapsedMs()
            )
        }

        // 2. Inline VNI override inside Smart Mode
        var workingText = text
        var inlineVNIConversions: [Int: String] = [:]
        if cfg.inlineVNIOverrideEnabled {
            let inlinePass = applyInlineVNIOverrides(text, using: vni)
            workingText = inlinePass.output
            inlineVNIConversions = inlinePass.convertedByWordIndex

            if inlinePass.allWordsConverted && inlinePass.convertedCount > 0 {
                teachInlineVNIConversions(
                    convertedByWordIndex: inlineVNIConversions,
                    finalText: workingText,
                    precedingContext: precedingContext
                )
                store.recordConversionEvent(source: .vniOverride)
                return ConversionResult(
                    originalText: text,
                    convertedText: workingText,
                    confidence: 1.0,
                    source: .vniOverride,
                    vietnameseRatio: 1.0,
                    alternatives: [],
                    latencyMs: elapsedMs()
                )
            }
        }

        // 3. Run LocalDiacriticEngine first (<1ms)
        let rawLocalResult = localEngine.convert(workingText, precedingContext: precedingContext)
        let normalizedLocalText = VNIEngine.normalizeOaOeUyToneStyle(
            rawLocalResult.convertedText,
            preferFirstVowel: cfg.modernTonePlacement
        )
        let normalizedLocalAlternatives = normalizeAlternatives(
            rawLocalResult.alternatives,
            preferFirstVowel: cfg.modernTonePlacement
        )
        let localResult = ConversionResult(
            originalText: text,
            convertedText: normalizedLocalText,
            confidence: rawLocalResult.confidence,
            source: rawLocalResult.source,
            vietnameseRatio: rawLocalResult.vietnameseRatio,
            alternatives: normalizedLocalAlternatives,
            latencyMs: rawLocalResult.latencyMs
        )

        // 4. Offline-only strategy or no API key configured -> stay 100% local
        if cfg.brainStrategy == .offlineOnly || !cfg.hasAPIKey {
            setLastGeminiSkipReason(.offline)
            return finishLocally(
                localResult,
                inlineVNIConversions: inlineVNIConversions,
                precedingContext: precedingContext
            )
        }

        // 5. The offline brain already knows the clause: verified phrase/context memory, a near-certain
        //    local answer, confident pure English, or (Hybrid) confidence above the user threshold.
        //    Calling the API here can only add cost.
        if shouldSkipAPIForKnownLocalClause(localResult, precedingContext: precedingContext)
            || (cfg.brainStrategy == .hybrid && localResult.confidence >= cfg.localConfidenceThreshold) {
            setLastGeminiSkipReason(.knownLocally)
            return finishLocally(
                localResult,
                inlineVNIConversions: inlineVNIConversions,
                precedingContext: precedingContext
            )
        }

        // 6. Dedupe: this exact clause + context tail + model was already answered by Gemini and the
        //    offline brain has not changed since. Serve it without touching the network, the usage
        //    ledger, or the learned data (the answer was learned when it was first produced).
        let correctionGeneration = store.correctionGeneration
        let cacheKey = geminiCacheKey(
            text: text,
            precedingContext: precedingContext,
            model: cfg.geminiModel
        )
        if let cached = cachedGeminiEntry(for: cacheKey, correctionGeneration: correctionGeneration) {
            setLastGeminiSkipReason(.cacheHit)
            store.recordConversionEvent(source: .localExact)
            return ConversionResult(
                originalText: text,
                convertedText: applyOuterWhitespace(of: text, toCore: cached.text),
                confidence: cached.confidence,
                source: .localExact,
                vietnameseRatio: cached.vietnameseRatio,
                alternatives: cached.alternatives,
                latencyMs: elapsedMs(),
                tokenUsage: nil
            )
        }

        // 7. Daily budget gate. Counts/costs come from the shared `api_usage` table because Kodau.app and
        //    KodauIM are separate processes writing to the same SQLite file; an in-memory counter would
        //    undercount and overspend.
        if let reason = dailyGeminiSkipReason(cfg: cfg) {
            setLastGeminiSkipReason(reason)
            return finishLocally(
                localResult,
                inlineVNIConversions: inlineVNIConversions,
                precedingContext: precedingContext
            )
        }

        // 8. Minimum spacing between calls. Cancellation here (the user resumed typing) still prevents
        //    the request from ever being sent.
        do {
            try await waitForGeminiSpacing(minIntervalSeconds: cfg.minGeminiIntervalSeconds)
        } catch {
            return finishLocally(
                localResult,
                inlineVNIConversions: inlineVNIConversions,
                precedingContext: precedingContext
            )
        }

        // 9. Escalate to Gemini API (cloudFirst, or hybrid below local confidence threshold).
        //    The request runs in a detached task: once it is in flight, caller cancellation (a newer
        //    keystroke) must not abort it, so usage accounting always matches Google's bill and the
        //    result is always learned/cached. The caller discards stale results via its own version guards.
        do {
            setLastGeminiSkipReason(nil)

            let restore = makeGeminiRestoreCall(
                text: workingText,
                precedingContext: precedingContext,
                apiKey: cfg.effectiveAPIKey,
                model: cfg.geminiModel
            )
            let requestTask = Task.detached(priority: .userInitiated) {
                try await restore()
            }
            let geminiResult = try await requestTask.value

            if let usage = geminiResult.tokenUsage {
                store.recordAPIUsage(usage, usdToVndRate: cfg.usdToVndRate)
            }

            // Preserve any explicit inline VNI overrides the user typed and normalize oa/oe/uy tone placement
            let enforcedText = enforceInlineVNIConversions(
                in: geminiResult.convertedText,
                overrides: inlineVNIConversions
            )
            let finalText = VNIEngine.normalizeOaOeUyToneStyle(
                enforcedText,
                preferFirstVowel: cfg.modernTonePlacement
            )
            let normalizedGeminiAlternatives = normalizeAlternatives(
                geminiResult.alternatives,
                preferFirstVowel: cfg.modernTonePlacement
            )

            // Distill & learn Gemini's restoration into the local SQLite brain
            store.learnFromText(finalText, source: "gemini", userVerified: false)

            if !inlineVNIConversions.isEmpty {
                teachInlineVNIConversions(
                    convertedByWordIndex: inlineVNIConversions,
                    finalText: finalText,
                    precedingContext: precedingContext
                )
            }

            store.recordConversionEvent(source: .geminiAPI)

            let cachedCore = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cachedCore.isEmpty {
                storeGeminiEntry(
                    GeminiCacheEntry(
                        text: cachedCore,
                        confidence: geminiResult.confidence,
                        vietnameseRatio: geminiResult.vietnameseRatio,
                        alternatives: normalizedGeminiAlternatives,
                        correctionGeneration: correctionGeneration,
                        storedAt: Date()
                    ),
                    for: cacheKey
                )
            }

            return ConversionResult(
                originalText: text,
                convertedText: finalText,
                confidence: geminiResult.confidence,
                source: .geminiAPI,
                vietnameseRatio: geminiResult.vietnameseRatio,
                alternatives: normalizedGeminiAlternatives,
                latencyMs: elapsedMs(),
                tokenUsage: geminiResult.tokenUsage
            )
        } catch {
            // Graceful fallback to LocalDiacriticEngine on any network/API error
            return finishLocally(
                localResult,
                inlineVNIConversions: inlineVNIConversions,
                precedingContext: precedingContext
            )
        }
    }

    /// Records a user correction from HUD, Playground, or retroactive VNI edit, immediately improving the Local Brain.
    public func applyUserCorrection(
        rawClause: String,
        currentConverted: String,
        wordIndex: Int,
        chosenWord: String
    ) -> String {
        let segments = TextSegmenter.segment(currentConverted)
        let wordSegments = segments.filter(\.isWord)
        guard wordIndex >= 0, wordIndex < wordSegments.count else {
            return currentConverted
        }

        let oldWord = wordSegments[wordIndex].raw
        let rawWords = TextSegmenter.wordTokens(from: rawClause)
        let baseWord: String
        if wordIndex < rawWords.count {
            baseWord = VNIEngine.stripDiacritics(rawWords[wordIndex]).lowercased()
        } else {
            baseWord = VNIEngine.stripDiacritics(oldWord).lowercased()
        }

        let prev1 = wordIndex >= 1 ? wordSegments[wordIndex - 1].raw.lowercased() : nil
        let prev2 = wordIndex >= 2 ? wordSegments[wordIndex - 2].raw.lowercased() : nil
        let next1 = wordIndex + 1 < wordSegments.count ? wordSegments[wordIndex + 1].raw.lowercased() : nil

        var updated = ""
        updated.reserveCapacity(currentConverted.count + 8)
        for seg in segments {
            if seg.isWord && seg.wordIndex == wordIndex {
                updated.append(chosenWord)
            } else {
                updated.append(seg.raw)
            }
        }

        store.recordUserCorrection(
            baseWord: baseWord,
            chosenSurface: chosenWord,
            prev1: prev1,
            prev2: prev2,
            next1: next1,
            fullRawClause: rawClause,
            fullCorrectedClause: updated
        )

        return updated
    }

    /// Records a word typed in VNI mode so VNI usage also trains the offline không-dấu brain.
    public func learnFromVNIWord(_ word: String, precedingContext: String = "") {
        let cfg = config
        guard cfg.learnFromVNIMode else { return }

        let wordTokens = TextSegmenter.wordTokens(from: word)
        guard let target = wordTokens.last, !target.isEmpty else { return }

        let ctxWords = TextSegmenter.wordTokens(from: precedingContext)
        let prev1 = ctxWords.last?.lowercased()
        let prev2 = ctxWords.count >= 2 ? ctxWords[ctxWords.count - 2].lowercased() : nil

        store.learnWordWithContext(
            surface: target,
            prev1: prev1,
            prev2: prev2,
            userVerified: true
        )
    }

    /// Exposes current stats for UI.
    public func currentStats() -> LearningStats {
        store.fetchStats()
    }

    /// Drops every memoized Gemini answer (e.g. after the user edits settings and wants a fresh pass).
    public func clearGeminiCache() {
        stateLock.lock()
        geminiCache.removeAll(keepingCapacity: false)
        geminiCacheOrder.removeAll(keepingCapacity: false)
        stateLock.unlock()
    }

    /// True when today's call count or estimated spend has reached the configured daily cap, so the UI can
    /// show an "offline until tomorrow" hint.
    public func isDailyGeminiBudgetExhausted() -> Bool {
        let cfg = snapshotState().0
        return dailyGeminiSkipReason(cfg: cfg) != nil
    }

    // MARK: - Private Helpers

    private func snapshotState() -> (AppConfig, VNIEngine) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (_config, _vniEngine)
    }

    /// Resolves which engine pipeline answers a request.
    ///
    /// `⌥Space` is allowed to force diacritic restoration while the user is in `.vni`, because VNI already
    /// inserts accented text and there is no ASCII buffer to convert. `.english` is never overridden: that mode
    /// is a strict pass-through contract, so a forced conversion would silently break "Tắt dấu".
    private func effectiveTypingMode(_ cfg: AppConfig, forceSmartEngine: Bool) -> TypingMode {
        guard forceSmartEngine, cfg.typingMode == .vni else { return cfg.typingMode }
        return .smart
    }

    private func setLastGeminiSkipReason(_ reason: GeminiSkipReason?) {
        stateLock.lock()
        _lastGeminiSkipReason = reason
        stateLock.unlock()
    }

    /// Shared tail for every path that answers from the offline brain.
    private func finishLocally(
        _ localResult: ConversionResult,
        inlineVNIConversions: [Int: String],
        precedingContext: String
    ) -> ConversionResult {
        if !inlineVNIConversions.isEmpty {
            teachInlineVNIConversions(
                convertedByWordIndex: inlineVNIConversions,
                finalText: localResult.convertedText,
                precedingContext: precedingContext
            )
        }
        store.recordConversionEvent(source: localResult.source)
        return localResult
    }

    /// True when the offline answer is already the best answer and the API cannot add value.
    ///
    /// `LocalDiacriticEngine.computeCalibratedConfidence` awards `0.95` per token when the chosen surface came
    /// from a user-verified context n-gram and clamps the blended clause score with `min(0.95, ...)`, so **a
    /// clause whose every Vietnamese word is backed by user-verified memory only reaches 0.95 — it can never
    /// reach 0.97**. Rather than adding a field to `ConversionResult` (the model layer is owned by another
    /// engineer), we verify the engine's own output against the store: if every Vietnamese word it emitted is
    /// stored as a user-verified surface for that word's left (or right) context, nothing is left to guess.
    private func shouldSkipAPIForKnownLocalClause(_ localResult: ConversionResult, precedingContext: String) -> Bool {
        if localResult.source == .localExact || localResult.source == .vniOverride {
            return true
        }
        if localResult.confidence >= 0.97 {
            return true
        }
        if localResult.source == .localEnglish && localResult.confidence >= 0.85 {
            return true
        }
        return isLocallyVerifiedClause(localResult.convertedText, precedingContext: precedingContext)
    }

    private func isLocallyVerifiedClause(_ convertedText: String, precedingContext: String) -> Bool {
        let words = TextSegmenter.wordTokens(from: convertedText)
        guard !words.isEmpty else { return false }
        // Left context of the first words = the text typed before this clause (or `<s>` at sentence start),
        // exactly what the engine decoded with.
        let contextWords = TextSegmenter.wordTokens(from: precedingContext).map { $0.lowercased() }

        var verifiedVietnameseWords = 0

        for idx in words.indices {
            let word = words[idx]
            let lower = word.lowercased()
            let base = VNIEngine.stripDiacritics(word).lowercased()
            guard !base.isEmpty else { continue }

            let hint = VietnamesePhonology.classifyToken(word)
            let isVietnamese = VNIEngine.containsVietnameseDiacritics(word)
                || hint == .definiteVietnamese
                || hint == .likelyVietnamese
            guard isVietnamese else { continue }

            let prev1 = idx >= 1
                ? words[idx - 1].lowercased()
                : (contextWords.last ?? LearningStore.sentenceStartToken)
            let prev2: String? = idx >= 2
                ? words[idx - 2].lowercased()
                : (idx == 1 ? contextWords.last : (contextWords.count >= 2 ? contextWords[contextWords.count - 2] : nil))
            let nextBase = idx + 1 < words.count
                ? VNIEngine.stripDiacritics(words[idx + 1]).lowercased()
                : nil

            var verified = false
            if let prev2 {
                verified = store.trigramCandidates(prev2: prev2, prev1: prev1, baseWord: base)
                    .contains { $0.userVerified && $0.surface.lowercased() == lower }
            }
            if !verified {
                verified = store.bigramCandidates(prevSurface: prev1, baseWord: base)
                    .contains { $0.userVerified && $0.surface.lowercased() == lower }
            }
            if !verified, let nextBase, !nextBase.isEmpty {
                verified = store.nextBigramCandidates(baseWord: base, nextBase: nextBase)
                    .contains { $0.userVerified && $0.surface.lowercased() == lower }
            }

            // One unverified Vietnamese word is enough for the API to still have something to improve.
            guard verified else { return false }
            verifiedVietnameseWords += 1
        }

        return verifiedVietnameseWords > 0
    }

    // MARK: - Gemini call policy helpers

    /// Daily call/spend gate read from the shared SQLite `api_usage` table.
    private func dailyGeminiSkipReason(cfg: AppConfig) -> GeminiSkipReason? {
        guard cfg.dailyGeminiCallLimit > 0 || cfg.dailyGeminiBudgetVND > 0 else { return nil }

        let today = store.fetchUsageSummary(period: .day, usdToVndRate: cfg.usdToVndRate)
        if cfg.dailyGeminiCallLimit > 0 && today.apiCalls >= cfg.dailyGeminiCallLimit {
            return .dailyCallLimit
        }
        if cfg.dailyGeminiBudgetVND > 0 && today.costVND >= cfg.dailyGeminiBudgetVND {
            return .dailyBudget
        }
        return nil
    }

    /// Reserves the next call slot and sleeps until the minimum spacing has elapsed. Throws
    /// `CancellationError` when the caller resumes typing during the wait.
    private func waitForGeminiSpacing(minIntervalSeconds: Double) async throws {
        let waitSeconds = reserveGeminiCallSlot(minIntervalSeconds: minIntervalSeconds)
        guard waitSeconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(waitSeconds * 1_000_000_000))
    }

    /// Synchronous so the lock is never taken directly inside an async context.
    private func reserveGeminiCallSlot(minIntervalSeconds: Double) -> TimeInterval {
        let now = Date()
        var waitSeconds: TimeInterval = 0

        stateLock.lock()
        if minIntervalSeconds > 0, let lastStart = _lastGeminiCallStartedAt {
            let elapsed = now.timeIntervalSince(lastStart)
            if elapsed < minIntervalSeconds {
                waitSeconds = minIntervalSeconds - elapsed
            }
        }
        _lastGeminiCallStartedAt = now.addingTimeInterval(waitSeconds)
        stateLock.unlock()

        return waitSeconds
    }

    private func makeGeminiRestoreCall(
        text: String,
        precedingContext: String,
        apiKey: String,
        model: String
    ) -> @Sendable () async throws -> ConversionResult {
        if let override = geminiRestoreOverride {
            return { try await override(text, precedingContext, apiKey, model) }
        }
        let client = geminiClient
        return {
            try await client.restoreDiacritics(
                text: text,
                precedingContext: precedingContext,
                apiKey: apiKey,
                model: model
            )
        }
    }

    /// Cache key: exact trimmed clause + last two context words (lowercased) + model.
    private func geminiCacheKey(text: String, precedingContext: String, model: String) -> String {
        let contextWords = TextSegmenter.wordTokens(from: precedingContext).suffix(2).map { $0.lowercased() }
        return [
            text.trimmingCharacters(in: .whitespacesAndNewlines),
            contextWords.joined(separator: " "),
            model
        ].joined(separator: "\u{1F}")
    }

    /// LRU lookup that also drops expired entries and entries invalidated by a learned-data change.
    private func cachedGeminiEntry(
        for key: String,
        correctionGeneration: UInt64
    ) -> GeminiCacheEntry? {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard let entry = geminiCache[key] else { return nil }

        let isExpired = Date().timeIntervalSince(entry.storedAt) > Self.geminiCacheTTL
        if isExpired || entry.correctionGeneration != correctionGeneration {
            geminiCache.removeValue(forKey: key)
            geminiCacheOrder.removeAll { $0 == key }
            return nil
        }

        geminiCacheOrder.removeAll { $0 == key }
        geminiCacheOrder.append(key)
        return entry
    }

    private func storeGeminiEntry(_ entry: GeminiCacheEntry, for key: String) {
        stateLock.lock()
        defer { stateLock.unlock() }

        geminiCache[key] = entry
        geminiCacheOrder.removeAll { $0 == key }
        geminiCacheOrder.append(key)

        while geminiCacheOrder.count > Self.geminiCacheCapacity {
            let evicted = geminiCacheOrder.removeFirst()
            geminiCache.removeValue(forKey: evicted)
        }
    }

    /// Rebuilds the exact original leading/trailing whitespace around a cached core text.
    private func applyOuterWhitespace(of source: String, toCore core: String) -> String {
        let leading = String(source.prefix(while: { $0.isWhitespace }))
        let trailing = String(source.reversed().prefix(while: { $0.isWhitespace }).reversed())
        return leading + core + trailing
    }

    private func normalizeAlternatives(
        _ alternatives: [WordAlternative],
        preferFirstVowel: Bool
    ) -> [WordAlternative] {
        guard !alternatives.isEmpty else { return [] }
        return alternatives.map { alt in
            let normalizedSelected = VNIEngine.normalizeOaOeUyToneStyle(
                alt.selected,
                preferFirstVowel: preferFirstVowel
            )
            var seen = Set<String>()
            var normalizedCandidates: [String] = []
            for cand in alt.candidates {
                let norm = VNIEngine.normalizeOaOeUyToneStyle(cand, preferFirstVowel: preferFirstVowel)
                if seen.insert(norm.lowercased()).inserted {
                    normalizedCandidates.append(norm)
                }
            }
            return WordAlternative(
                id: alt.id,
                wordIndex: alt.wordIndex,
                baseWord: alt.baseWord,
                selected: normalizedSelected,
                candidates: normalizedCandidates
            )
        }
    }

    private struct InlineVNIPassResult {
        let output: String
        let convertedByWordIndex: [Int: String]
        let convertedCount: Int
        let allWordsConverted: Bool
    }

    private func applyInlineVNIOverrides(_ text: String, using vni: VNIEngine) -> InlineVNIPassResult {
        let segments = TextSegmenter.segment(text)
        let totalWords = segments.filter(\.isWord).count
        guard totalWords > 0 else {
            return InlineVNIPassResult(output: text, convertedByWordIndex: [:], convertedCount: 0, allWordsConverted: false)
        }

        var output = ""
        output.reserveCapacity(text.count)
        var convertedMap: [Int: String] = [:]

        for seg in segments {
            if !seg.isWord {
                output.append(seg.raw)
                continue
            }

            if vni.looksLikeInlineVNI(seg.raw) {
                let (converted, didConvert) = vni.convertWord(seg.raw)
                if didConvert {
                    convertedMap[seg.wordIndex] = converted
                    output.append(converted)
                    continue
                }
            }

            output.append(seg.raw)
        }

        return InlineVNIPassResult(
            output: output,
            convertedByWordIndex: convertedMap,
            convertedCount: convertedMap.count,
            allWordsConverted: convertedMap.count == totalWords
        )
    }

    private func convertAllVNITokens(_ text: String, using vni: VNIEngine) -> (output: String, didConvertAny: Bool) {
        let segments = TextSegmenter.segment(text)
        var output = ""
        output.reserveCapacity(text.count)
        var didConvertAny = false

        for seg in segments {
            if !seg.isWord {
                output.append(seg.raw)
            } else {
                let (converted, didConvert) = vni.convertWord(seg.raw)
                if didConvert {
                    didConvertAny = true
                    output.append(converted)
                } else {
                    output.append(seg.raw)
                }
            }
        }

        return (output, didConvertAny)
    }

    private func enforceInlineVNIConversions(in text: String, overrides: [Int: String]) -> String {
        guard !overrides.isEmpty else { return text }
        let segments = TextSegmenter.segment(text)
        var rebuilt = ""
        rebuilt.reserveCapacity(text.count)
        for seg in segments {
            if seg.isWord, let forced = overrides[seg.wordIndex] {
                rebuilt.append(forced)
            } else {
                rebuilt.append(seg.raw)
            }
        }
        return rebuilt
    }

    private func teachInlineVNIConversions(
        convertedByWordIndex: [Int: String],
        finalText: String,
        precedingContext: String
    ) {
        let finalWords = TextSegmenter.wordTokens(from: finalText)
        let ctxWords = TextSegmenter.wordTokens(from: precedingContext)
        let ctxPrev1 = ctxWords.last?.lowercased()
        let ctxPrev2 = ctxWords.count >= 2 ? ctxWords[ctxWords.count - 2].lowercased() : nil

        for (idx, converted) in convertedByWordIndex.sorted(by: { $0.key < $1.key }) {
            let base = VNIEngine.stripDiacritics(converted).lowercased()
            let prev1: String?
            let prev2: String?

            if idx >= 2, idx < finalWords.count {
                prev1 = finalWords[idx - 1].lowercased()
                prev2 = finalWords[idx - 2].lowercased()
            } else if idx == 1, idx < finalWords.count {
                prev1 = finalWords[0].lowercased()
                prev2 = ctxPrev1
            } else {
                prev1 = ctxPrev1
                prev2 = ctxPrev2
            }

            store.recordUserCorrection(
                baseWord: base,
                chosenSurface: converted,
                prev1: prev1,
                prev2: prev2,
                next1: idx + 1 < finalWords.count ? finalWords[idx + 1] : nil
            )
        }
    }
}
