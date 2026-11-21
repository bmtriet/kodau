import Testing
import Foundation
@testable import KodauCore

/// Thread-safe counter of the (stubbed) Gemini calls made during a test.
private final class GeminiCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _starts: [Date] = []

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _starts.count
    }

    var starts: [Date] {
        lock.lock()
        defer { lock.unlock() }
        return _starts
    }

    func recordStart() {
        lock.lock()
        _starts.append(Date())
        lock.unlock()
    }
}

private func mockGeminiResult(
    for text: String,
    converted: String = "dương",
    usage: TokenUsage? = TokenUsage(model: "gemini-2.5-flash-lite", promptTokens: 20, outputTokens: 10)
) -> ConversionResult {
    ConversionResult(
        originalText: text,
        convertedText: converted,
        confidence: 0.92,
        source: .geminiAPI,
        vietnameseRatio: 0.9,
        alternatives: [],
        latencyMs: 1,
        tokenUsage: usage
    )
}

private func cloudConfig(
    dailyGeminiCallLimit: Int = 0,
    dailyGeminiBudgetVND: Double = 0,
    minGeminiIntervalSeconds: Double = 0
) -> AppConfig {
    AppConfig(
        typingMode: .smart,
        brainStrategy: .cloudFirst,
        geminiAPIKey: "test-key",
        dailyGeminiCallLimit: dailyGeminiCallLimit,
        dailyGeminiBudgetVND: dailyGeminiBudgetVND,
        minGeminiIntervalSeconds: minGeminiIntervalSeconds
    )
}

@Suite("Gemini Call Policy Tests")
final class GeminiCallPolicyTests {
    private let dbURL: URL
    private let store: LearningStore

    init() throws {
        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kodau-gemini-policy-\(UUID().uuidString).sqlite")
        store = try LearningStore(databaseURL: dbURL)
    }

    deinit {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbURL.path + suffix)
        }
    }

    private func makeCoordinator(_ config: AppConfig) -> SmartCoordinator {
        SmartCoordinator(store: store, config: config, geminiClient: GeminiClient())
    }

    // MARK: - Result cache

    @Test("A repeated clause is served from the cache: no 2nd API call, no usage, no re-learning")
    func cacheHitAvoidsSecondCall() async {
        let recorder = GeminiCallRecorder()
        let coordinator = makeCoordinator(cloudConfig())
        coordinator.geminiRestoreOverride = { text, _, _, _ in
            recorder.recordStart()
            return mockGeminiResult(for: text)
        }

        let first = await coordinator.convertSmart("duong")
        #expect(first.source == .geminiAPI)
        #expect(recorder.count == 1)
        #expect(coordinator.lastGeminiSkipReason == nil)

        let callsAfterFirst = store.fetchUsageSummary(period: .day, usdToVndRate: 25_800).apiCalls
        #expect(callsAfterFirst == 1)

        let second = await coordinator.convertSmart("duong")
        #expect(recorder.count == 1, "Cached clause must not reach the API a second time")
        #expect(second.convertedText == "dương")
        #expect(second.source == .localExact)
        #expect(second.tokenUsage == nil)
        #expect(coordinator.lastGeminiSkipReason == .cacheHit)
        #expect(store.fetchUsageSummary(period: .day, usdToVndRate: 25_800).apiCalls == 1)
        #expect(store.fetchStats().geminiConversions == 1, "Cache hit must not be re-learned or re-counted")
    }

    @Test("A user correction bumps correctionGeneration and invalidates the cache")
    func correctionGenerationInvalidatesCache() async {
        let recorder = GeminiCallRecorder()
        let coordinator = makeCoordinator(cloudConfig())
        coordinator.geminiRestoreOverride = { text, _, _, _ in
            recorder.recordStart()
            return mockGeminiResult(for: text)
        }

        let generationBefore = store.correctionGeneration
        _ = await coordinator.convertSmart("duong")
        #expect(recorder.count == 1)

        // Unrelated correction: the cached clause itself stays valid textually, but the brain changed.
        store.recordUserCorrection(baseWord: "ban", chosenSurface: "bàn", prev1: "cái", next1: "gỗ")
        #expect(store.correctionGeneration > generationBefore)

        let third = await coordinator.convertSmart("duong")
        #expect(recorder.count == 2, "Cache entry must be invalidated after a learned-data change")
        #expect(third.source == .geminiAPI)
        #expect(coordinator.lastGeminiSkipReason == nil)
    }

    @Test("clearGeminiCache drops memoized answers")
    func clearGeminiCacheForcesFreshCall() async {
        let recorder = GeminiCallRecorder()
        let coordinator = makeCoordinator(cloudConfig())
        coordinator.geminiRestoreOverride = { text, _, _, _ in
            recorder.recordStart()
            return mockGeminiResult(for: text)
        }

        _ = await coordinator.convertSmart("duong")
        coordinator.clearGeminiCache()
        _ = await coordinator.convertSmart("duong")

        #expect(recorder.count == 2)
    }

    // MARK: - Known locally

    @Test("Phrase memory (localExact) skips the API even under cloudFirst")
    func phraseMemorySkipsAPIUnderCloudFirst() async {
        let recorder = GeminiCallRecorder()
        let coordinator = makeCoordinator(cloudConfig())
        coordinator.geminiRestoreOverride = { text, _, _, _ in
            recorder.recordStart()
            return mockGeminiResult(for: text)
        }

        store.learnFromText("xin chào", source: "seed")

        let result = await coordinator.convertSmart("xin chao")
        #expect(recorder.count == 0, "A known phrase must not be sent to Gemini")
        #expect(result.source == .localExact)
        #expect(result.convertedText == "xin chào")
        #expect(coordinator.lastGeminiSkipReason == .knownLocally)
    }

    /// Documents the confidence calibration behind the 0.97 rule: a clause whose every Vietnamese word was
    /// chosen from a user-verified context n-gram is capped at 0.95 by `computeCalibratedConfidence`
    /// (`hadUserVerified -> 0.95` per token, then `min(0.95, ...)`), so the skip decision cannot rely on
    /// confidence alone — it verifies the engine's output against the store instead.
    @Test("A fully user-verified clause is capped at 0.95 yet still skips the API")
    func verifiedClauseSkipsDespiteConfidenceCap() async {
        let recorder = GeminiCallRecorder()
        let coordinator = makeCoordinator(cloudConfig())
        coordinator.geminiRestoreOverride = { text, _, _, _ in
            recorder.recordStart()
            return mockGeminiResult(for: text)
        }

        store.recordUserCorrection(baseWord: "toi", chosenSurface: "tôi", prev1: nil, next1: "ban")
        store.recordUserCorrection(baseWord: "ban", chosenSurface: "bán", prev1: "tôi", next1: "hang")
        store.recordUserCorrection(baseWord: "hang", chosenSurface: "hàng", prev1: "bán", next1: nil)

        let local = coordinator.convertSync("toi ban hang")
        #expect(local.source == .localViterbi)
        #expect(local.confidence <= 0.95, "Calibrated confidence never reaches 0.97 for a fully verified clause")

        let result = await coordinator.convertSmart("toi ban hang")
        #expect(recorder.count == 0)
        #expect(result.source == .localViterbi)
        #expect(coordinator.lastGeminiSkipReason == .knownLocally)
    }

    // MARK: - Daily budget gate

    @Test("Daily call limit blocks the API and reports why")
    func dailyCallLimitBlocks() async {
        let recorder = GeminiCallRecorder()
        let config = cloudConfig(dailyGeminiCallLimit: 1)
        let coordinator = makeCoordinator(config)
        coordinator.geminiRestoreOverride = { text, _, _, _ in
            recorder.recordStart()
            return mockGeminiResult(for: text)
        }

        store.recordAPIUsage(
            TokenUsage(model: "gemini-2.5-flash-lite", promptTokens: 10, outputTokens: 5),
            usdToVndRate: config.usdToVndRate
        )

        let result = await coordinator.convertSmart("duong")
        #expect(recorder.count == 0)
        #expect(result.source != .geminiAPI)
        #expect(coordinator.lastGeminiSkipReason == .dailyCallLimit)
        #expect(coordinator.isDailyGeminiBudgetExhausted())
    }

    @Test("Daily VND budget blocks the API and reports why")
    func dailyBudgetBlocks() async {
        let recorder = GeminiCallRecorder()
        let config = cloudConfig(dailyGeminiBudgetVND: 1.0)
        let coordinator = makeCoordinator(config)
        coordinator.geminiRestoreOverride = { text, _, _, _ in
            recorder.recordStart()
            return mockGeminiResult(for: text)
        }

        store.recordAPIUsage(
            TokenUsage(model: "gemini-2.5-flash-lite", promptTokens: 1_000_000, outputTokens: 0),
            usdToVndRate: config.usdToVndRate
        )

        let result = await coordinator.convertSmart("duong")
        #expect(recorder.count == 0)
        #expect(result.source != .geminiAPI)
        #expect(coordinator.lastGeminiSkipReason == .dailyBudget)
        #expect(coordinator.isDailyGeminiBudgetExhausted())
    }

    // MARK: - Minimum spacing

    @Test("Minimum interval delays the second call")
    func minimumIntervalDelaysSecondCall() async {
        let recorder = GeminiCallRecorder()
        let coordinator = makeCoordinator(cloudConfig(minGeminiIntervalSeconds: 0.4))
        coordinator.geminiRestoreOverride = { text, _, _, _ in
            recorder.recordStart()
            return mockGeminiResult(for: text)
        }

        _ = await coordinator.convertSmart("duong")
        _ = await coordinator.convertSmart("nhanh")

        let starts = recorder.starts
        #expect(starts.count == 2)
        guard starts.count == 2 else { return }
        let delta = starts[1].timeIntervalSince(starts[0])
        #expect(delta >= 0.3, "Second call should wait out the minimum interval, got \(delta)s")
    }

    // MARK: - In-flight request survives caller cancellation

    @Test("A cancelled caller still records usage for a request already sent")
    func cancelledCallerStillRecordsUsage() async throws {
        let recorder = GeminiCallRecorder()
        let coordinator = makeCoordinator(cloudConfig())
        coordinator.geminiRestoreOverride = { text, _, _, _ in
            recorder.recordStart()
            // Simulates the HTTP round-trip already being in flight.
            try await Task.sleep(nanoseconds: 250_000_000)
            return mockGeminiResult(for: text)
        }

        let call = Task { await coordinator.convertSmart("duong") }

        var waitedMs = 0
        while recorder.count == 0 && waitedMs < 200 {
            try await Task.sleep(nanoseconds: 10_000_000)
            waitedMs += 10
        }
        #expect(recorder.count == 1, "The request should already be in flight before cancelling")

        call.cancel()
        _ = await call.value

        #expect(recorder.count == 1)
        #expect(
            store.fetchUsageSummary(period: .day, usdToVndRate: 25_800).apiCalls == 1,
            "An in-flight call completed after cancellation must still be billed/counted"
        )
        #expect(store.fetchStats().geminiConversions == 1)

        // The result was learned and cached despite the cancelled caller.
        let cachedFollowUp = await coordinator.convertSmart("duong")
        #expect(recorder.count == 1)
        #expect(cachedFollowUp.source == .localExact)
        #expect(coordinator.lastGeminiSkipReason == .cacheHit)
    }
}
