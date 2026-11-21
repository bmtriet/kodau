import Foundation
import Testing
@testable import KodauCore

@Suite("LearningStore and SmartCoordinator Tests")
final class LearningAndCoordinatorTests {

    private let tempDBURL: URL
    private let store: LearningStore

    init() throws {
        tempDBURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kodau_learning_tests_\(UUID().uuidString).sqlite")
        store = try LearningStore(databaseURL: tempDBURL)
    }

    deinit {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: tempDBURL.path + suffix)
        }
    }

    // MARK: - LearningStore Basics (Unigram / Bigram / Trigram / Phrase)

    @Test("LearningStore records and recalls unigrams, bigrams, trigrams, and phrases")
    func testLearnFromTextAndNGramRecall() throws {
        store.learnFromText(
            "tôi rất thích uống cà phê sáng",
            source: "test",
            userVerified: true
        )

        // Unigram recall: learned as a weak, context-free prior (never a verified global replace rule)
        let unigrams = store.unigramCandidates(for: "phe")
        #expect(
            unigrams.contains(where: { $0.surface == "phê" && !$0.userVerified && $0.count >= 1 }),
            "Expected unigram 'phê' to be learned as an unverified prior, got: \(unigrams)"
        )

        // Right-context recall ("phê" is followed by "sáng"), verified because the source text was verified
        let nextContext = store.nextBigramCandidates(baseWord: "phe", nextBase: "sang")
        #expect(nextContext.contains(where: { $0.surface == "phê" && $0.userVerified }))

        // Sentence-start context ("<s>" -> "tôi")
        let startContext = store.bigramCandidates(prevSurface: LearningStore.sentenceStartToken, baseWord: "toi")
        #expect(startContext.contains(where: { $0.surface == "tôi" }))

        // Bigram recall ("cà" -> "phê")
        let bigrams = store.bigramCandidates(prevSurface: "cà", baseWord: "phe")
        #expect(
            bigrams.contains(where: { $0.surface == "phê" && $0.userVerified }),
            "Expected bigram ('cà', 'phe' -> 'phê'), got: \(bigrams)"
        )

        // Trigram recall ("uống", "cà" -> "phê")
        let trigrams = store.trigramCandidates(prev2: "uống", prev1: "cà", baseWord: "phe")
        #expect(
            trigrams.contains(where: { $0.surface == "phê" && $0.userVerified }),
            "Expected trigram ('uống', 'cà', 'phe' -> 'phê'), got: \(trigrams)"
        )

        // Exact phrase recall
        let phrase = try #require(store.lookupPhrase(rawNoDiacritics: "toi rat thich uong ca phe sang"))
        #expect(phrase.restored == "tôi rất thích uống cà phê sáng")
        #expect(phrase.userCorrected)
        #expect(phrase.useCount >= 1)
    }

    @Test("Corpus import, fetch queries, JSONL export, and reset")
    func testCorpusImportFetchAndJSONLExport() throws {
        let corpus = """
        hôm nay trời đẹp quá
        chúng tôi đang phát triển phần mềm tiếng việt
        cảm ơn bạn đã hỗ trợ dự án này
        """

        let importedCount = store.importCorpus(corpus)
        #expect(importedCount > 0)

        let stats = store.fetchStats()
        #expect(stats.uniqueWordsLearned > 5)
        #expect(stats.uniqueBigramsLearned > 5)

        let allEntries = store.fetchLearnedEntries(search: "", limit: 100)
        #expect(!allEntries.isEmpty)

        let filteredEntries = store.fetchLearnedEntries(search: "viet", limit: 20)
        #expect(filteredEntries.contains(where: { $0.baseWord == "viet" && $0.surfaceForm == "việt" }))

        let phrases = store.fetchLearnedPhrases(search: "", limit: 50)
        #expect(!phrases.isEmpty)

        // Export JSONL and verify valid JSON lines
        let jsonl = store.exportDatasetJSONL()
        #expect(!jsonl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let lines = jsonl
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        #expect(!lines.isEmpty)

        for line in lines {
            let data = try #require(line.data(using: .utf8))
            let obj = try JSONSerialization.jsonObject(with: data)
            #expect(obj is [String: Any], "Each JSONL line must be a JSON object")
        }

        // Reset clears learned data
        store.resetAllData()
        let afterReset = store.fetchStats()
        #expect(afterReset.uniqueWordsLearned == 0)
        #expect(afterReset.uniqueBigramsLearned == 0)
        #expect(afterReset.uniquePhrasesLearned == 0)
        #expect(store.fetchLearnedEntries(search: "", limit: 20).isEmpty)
    }

    // MARK: - User Correction Guiding Overrides Default Immediately

    @Test("Contextual user correction overrides default unigram immediately offline")
    func testUserCorrectionOverridesDefaultUnigramOffline() {
        let engine = LocalDiacriticEngine(store: store)
        let rawInput = "toi xem ban nay"

        let initial = engine.convert(rawInput, precedingContext: "")
        let initialTokens = initial.convertedText.split(separator: " ").map(String.init)
        #expect(initialTokens.count == 4, "Unexpected token count: \(initial.convertedText)")

        // Pick a valid Vietnamese form for "ban" that differs from the engine's initial choice
        let customChoice = (initialTokens[2].lowercased() == "bản") ? "bàn" : "bản"

        store.recordUserCorrection(
            baseWord: "ban",
            chosenSurface: customChoice,
            prev1: initialTokens[1],
            prev2: initialTokens[0],
            fullRawClause: nil,
            fullCorrectedClause: nil
        )

        let updated = engine.convert(rawInput, precedingContext: "")
        let updatedTokens = updated.convertedText.split(separator: " ").map(String.init)
        #expect(updatedTokens.count == 4)
        #expect(
            updatedTokens[2].lowercased() == customChoice,
            "User contextual correction should immediately override default choice on next offline conversion"
        )
    }

    @Test("SmartCoordinator applyUserCorrection persists and guides next conversion")
    func testCoordinatorApplyUserCorrectionPersistsAndGuides() {
        let config = AppConfig(
            typingMode: .smart,
            brainStrategy: .offlineOnly,
            geminiAPIKey: ""
        )
        let coordinator = SmartCoordinator(store: store, config: config, geminiClient: GeminiClient())

        let rawClause = "toi mua ban moi"
        let initial = coordinator.convertSync(rawClause, precedingContext: "")
        let tokens = initial.convertedText.split(separator: " ").map(String.init)
        #expect(tokens.count == 4)

        let chosenWord = (tokens[2].lowercased() == "bàn") ? "bản" : "bàn"
        let corrected = coordinator.applyUserCorrection(
            rawClause: rawClause,
            currentConverted: initial.convertedText,
            wordIndex: 2,
            chosenWord: chosenWord
        )

        let correctedTokens = corrected.split(separator: " ").map(String.init)
        #expect(correctedTokens.count == 4)
        #expect(correctedTokens[2] == chosenWord)

        // Next offline conversion immediately uses the corrected choice
        let nextResult = coordinator.convertSync(rawClause, precedingContext: "")
        #expect(nextResult.convertedText == corrected)

        let stats = coordinator.currentStats()
        #expect(stats.userCorrections >= 1)
    }

    // MARK: - SmartCoordinator Offline-Only Mode

    @Test("SmartCoordinator offline-only mode never calls Gemini API")
    func testSmartCoordinatorOfflineOnlyMode() async {
        let config = AppConfig(
            typingMode: .smart,
            brainStrategy: .offlineOnly,
            geminiAPIKey: ""
        )
        let coordinator = SmartCoordinator(store: store, config: config, geminiClient: GeminiClient())

        let syncResult = coordinator.convertSync("hom nay toi di lam", precedingContext: "")
        #expect(syncResult.convertedText == "hôm nay tôi đi làm")
        #expect(syncResult.source.isOffline)
        #expect(syncResult.source != .geminiAPI)

        let asyncResult = await coordinator.convertSmart("tieng viet khong dau", precedingContext: "")
        #expect(asyncResult.convertedText == "tiếng việt không dấu")
        #expect(asyncResult.source.isOffline)
        #expect(asyncResult.source != .geminiAPI)

        let englishResult = await coordinator.convertSmart("Please check the server logs", precedingContext: "")
        #expect(englishResult.convertedText == "Please check the server logs")
        #expect(englishResult.source == .localEnglish)
    }

    // MARK: - Inline VNI Override in Smart Mode

    @Test("Inline VNI override converts and learns verified word")
    func testInlineVNIOverrideConvertsAndLearnsVerifiedWord() async {
        let config = AppConfig(
            typingMode: .smart,
            brainStrategy: .offlineOnly,
            geminiAPIKey: "",
            inlineVNIOverrideEnabled: true
        )
        let coordinator = SmartCoordinator(store: store, config: config, geminiClient: GeminiClient())

        let syncResult = coordinator.convertSync("toi dang go tie6ng1 viet", precedingContext: "")
        #expect(syncResult.didChange)
        #expect(
            syncResult.convertedText.contains("tiếng"),
            "Expected sync inline VNI 'tie6ng1' to convert to 'tiếng', got: \(syncResult.convertedText)"
        )

        let result = await coordinator.convertSmart("toi dang go tie6ng1 viet", precedingContext: "")
        #expect(result.didChange)
        #expect(
            result.convertedText.contains("tiếng"),
            "Expected inline VNI 'tie6ng1' to convert to 'tiếng', got: \(result.convertedText)"
        )
        #expect(
            !result.convertedText.contains("tie6ng1"),
            "Raw inline VNI sequence should not remain in output"
        )

        // Inline VNI teaches 'tiếng' in context (next word "việt"), not as a global replace rule
        let candidates = store.unigramCandidates(for: "tieng")
        #expect(candidates.contains(where: { $0.surface == "tiếng" }))
        let nextContext = store.nextBigramCandidates(baseWord: "tieng", nextBase: "viet")
        #expect(
            nextContext.contains(where: { $0.surface == "tiếng" && $0.userVerified }),
            "Inline VNI override should teach 'tiếng' as user-verified in its context, got: \(nextContext)"
        )
    }

    // MARK: - VNI Word Learning & Config Updates

    @Test("learnFromVNIWord trains store and respects learnFromVNIMode config")
    func testLearnFromVNIWordAndConfigToggle() {
        var config = AppConfig(
            typingMode: .vni,
            brainStrategy: .offlineOnly,
            learnFromVNIMode: true
        )
        let coordinator = SmartCoordinator(store: store, config: config, geminiClient: GeminiClient())

        coordinator.learnFromVNIWord("phở", precedingContext: "tôi ăn")

        let phoUnigrams = store.unigramCandidates(for: "pho")
        #expect(
            phoUnigrams.contains(where: { $0.surface == "phở" }),
            "Expected VNI word 'phở' to be stored, got: \(phoUnigrams)"
        )

        let phoBigrams = store.bigramCandidates(prevSurface: "ăn", baseWord: "pho")
        #expect(
            phoBigrams.contains(where: { $0.surface == "phở" }),
            "Expected VNI bigram ('ăn', 'pho' -> 'phở') to be stored, got: \(phoBigrams)"
        )

        // Disabling learnFromVNIMode stops recording new VNI words
        config.learnFromVNIMode = false
        coordinator.updateConfig(config)
        coordinator.learnFromVNIWord("bún", precedingContext: "tôi ăn")

        let bunUnigrams = store.unigramCandidates(for: "bun")
        #expect(
            !bunUnigrams.contains(where: { $0.surface == "bún" }),
            "Expected VNI learning to be skipped when learnFromVNIMode is false"
        )
    }

    // MARK: - Stats & Independence Score Progression

    @Test("Stats and independence score progression")
    func testStatsAndIndependenceScoreProgression() async {
        let config = AppConfig(
            typingMode: .smart,
            brainStrategy: .offlineOnly,
            geminiAPIKey: ""
        )
        let coordinator = SmartCoordinator(store: store, config: config, geminiClient: GeminiClient())

        let initialStats = coordinator.currentStats()
        #expect(initialStats.totalConversions == 0)
        #expect(abs(initialStats.independenceScore - 0.0) <= 0.0001)
        #expect(initialStats.stage == .bootstrap)

        // Feed corpus, conversions, and user corrections
        let corpus = """
        hôm nay tôi đi làm rất sớm
        chúng tôi đang xây dựng bộ gõ tiếng việt thông minh
        mọi dữ liệu học tập được lưu trữ cục bộ trên máy
        cảm ơn bạn đã sử dụng phần mềm mỗi ngày
        """
        _ = store.importCorpus(corpus)

        for _ in 0..<10 {
            _ = await coordinator.convertSmart("hom nay toi di lam", precedingContext: "")
        }

        store.recordUserCorrection(
            baseWord: "ban",
            chosenSurface: "bạn",
            prev1: "ơn",
            prev2: "cảm",
            fullRawClause: "cam on ban",
            fullCorrectedClause: "cảm ơn bạn"
        )
        store.recordConversionEvent(source: .localExact)

        let progressedStats = coordinator.currentStats()
        #expect(progressedStats.totalConversions > initialStats.totalConversions)
        #expect(progressedStats.localConversions > 0)
        #expect(progressedStats.geminiConversions == 0)
        #expect(progressedStats.uniqueWordsLearned > 0)
        #expect(progressedStats.uniqueBigramsLearned > 0)
        #expect(progressedStats.userCorrections > 0)
        #expect(progressedStats.offlineHitRate > 0.9)
        #expect(progressedStats.independenceScore > initialStats.independenceScore)

        // Verify LearningStats stage progression boundaries
        let learningStageStats = LearningStats(
            totalConversions: 30,
            localConversions: 24,
            geminiConversions: 6,
            userCorrections: 10,
            uniqueWordsLearned: 120,
            uniqueBigramsLearned: 180,
            uniquePhrasesLearned: 25
        )
        #expect(learningStageStats.stage == .learning)

        let proficientStageStats = LearningStats(
            totalConversions: 80,
            localConversions: 72,
            geminiConversions: 8,
            userCorrections: 30,
            uniqueWordsLearned: 300,
            uniqueBigramsLearned: 500,
            uniquePhrasesLearned: 60
        )
        #expect(proficientStageStats.stage == .proficient)

        let independentStageStats = LearningStats(
            totalConversions: 150,
            localConversions: 145,
            geminiConversions: 5,
            userCorrections: 50,
            uniqueWordsLearned: 450,
            uniqueBigramsLearned: 900,
            uniquePhrasesLearned: 120
        )
        #expect(independentStageStats.stage == .independent)
        #expect(independentStageStats.independenceScore >= 0.85)
    }

    // MARK: - API Usage & Cost Telemetry

    @Test("LearningStore records API usage, aggregates across periods, calculates VND, and returns breakdown buckets")
    func testAPIUsageTrackingAndPeriodSummaries() throws {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current

        // Anchor "now" to a deterministic mid-week/mid-month date: Wednesday 2026-06-17 15:30:00 local time
        let nowComponents = DateComponents(year: 2026, month: 6, day: 17, hour: 15, minute: 30)
        let now = try #require(calendar.date(from: nowComponents))

        // 1. Today (earlier hour: 09:15)
        let todayMorning = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 17, hour: 9, minute: 15)))
        // 2. Today (same hour: 15:00)
        let todayAfternoon = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 17, hour: 15, minute: 0)))
        // 3. Earlier this week (Monday 2026-06-15 10:00)
        let earlierThisWeek = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 10, minute: 0)))
        // 4. Earlier this month (2026-06-02 10:00)
        let earlierThisMonth = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 2, hour: 10, minute: 0)))
        // 5. Earlier this year (2026-02-10 10:00)
        let earlierThisYear = try #require(calendar.date(from: DateComponents(year: 2026, month: 2, day: 10, hour: 10, minute: 0)))
        // 6. Previous year (2025-11-20 10:00)
        let lastYear = try #require(calendar.date(from: DateComponents(year: 2025, month: 11, day: 20, hour: 10, minute: 0)))

        // Use gemini-2.5-flash-lite: input $0.10 / 1M, output $0.40 / 1M
        // For 1000 prompt + 500 output:
        // costUSD = (1000 / 1_000_000) * 0.10 + (500 / 1_000_000) * 0.40 = 0.0001 + 0.0002 = 0.0003 USD
        let usage = TokenUsage(model: "gemini-2.5-flash-lite", promptTokens: 1_000, outputTokens: 500, totalTokens: 1_500)
        let expectedSingleCostUSD = 0.0003
        #expect(abs(usage.estimatedCostUSD() - expectedSingleCostUSD) < 1e-9)

        let rate = 25_000.0
        for ts in [todayMorning, todayAfternoon, earlierThisWeek, earlierThisMonth, earlierThisYear, lastYear] {
            store.recordAPIUsage(usage, usdToVndRate: rate, timestamp: ts)
        }

        // Day summary: 2 calls (todayMorning, todayAfternoon)
        let daySummary = store.fetchUsageSummary(period: .day, usdToVndRate: rate, now: now)
        #expect(daySummary.apiCalls == 2)
        #expect(daySummary.promptTokens == 2_000)
        #expect(daySummary.outputTokens == 1_000)
        #expect(daySummary.totalTokens == 3_000)
        #expect(abs(daySummary.costUSD - expectedSingleCostUSD * 2) < 1e-9)
        #expect(abs(daySummary.costVND - expectedSingleCostUSD * 2 * rate) < 1e-6)

        // Dynamic VND recalculation with different exchange rate
        let customRate = 26_500.0
        let dayCustomVND = store.fetchUsageSummary(period: .day, usdToVndRate: customRate, now: now)
        #expect(abs(dayCustomVND.costVND - expectedSingleCostUSD * 2 * customRate) < 1e-6)

        // Week summary: 3 calls (todayMorning, todayAfternoon, earlierThisWeek)
        let weekSummary = store.fetchUsageSummary(period: .week, usdToVndRate: rate, now: now)
        #expect(weekSummary.apiCalls == 3)
        #expect(weekSummary.totalTokens == 4_500)

        // Month summary: 4 calls
        let monthSummary = store.fetchUsageSummary(period: .month, usdToVndRate: rate, now: now)
        #expect(monthSummary.apiCalls == 4)
        #expect(monthSummary.totalTokens == 6_000)

        // Year summary: 5 calls
        let yearSummary = store.fetchUsageSummary(period: .year, usdToVndRate: rate, now: now)
        #expect(yearSummary.apiCalls == 5)
        #expect(yearSummary.totalTokens == 7_500)

        // All-time summary: 6 calls
        let allTimeSummary = store.fetchUsageSummary(period: .allTime, usdToVndRate: rate, now: now)
        #expect(allTimeSummary.apiCalls == 6)
        #expect(allTimeSummary.totalTokens == 9_000)
        #expect(abs(allTimeSummary.costVND - expectedSingleCostUSD * 6 * rate) < 1e-6)

        // fetchAllPeriodSummaries returns all 5 periods
        let allSummaries = store.fetchAllPeriodSummaries(usdToVndRate: rate, now: now)
        #expect(allSummaries.count == UsagePeriod.allCases.count)

        // Breakdown buckets
        let dayBuckets = store.fetchUsageBreakdown(period: .day, usdToVndRate: rate, now: now)
        #expect(dayBuckets.map(\.label) == ["09h", "15h"])
        #expect(dayBuckets.allSatisfy { $0.apiCalls == 1 })

        let weekBuckets = store.fetchUsageBreakdown(period: .week, usdToVndRate: rate, now: now)
        #expect(weekBuckets.map(\.label) == ["15/06", "17/06"])
        #expect(weekBuckets[0].apiCalls == 1)
        #expect(weekBuckets[1].apiCalls == 2)

        let monthBuckets = store.fetchUsageBreakdown(period: .month, usdToVndRate: rate, now: now)
        #expect(monthBuckets.map(\.label) == ["02/06", "15/06", "17/06"])

        let yearBuckets = store.fetchUsageBreakdown(period: .year, usdToVndRate: rate, now: now)
        #expect(yearBuckets.map(\.label) == ["T2/2026", "T6/2026"])
        #expect(yearBuckets[0].apiCalls == 1)
        #expect(yearBuckets[1].apiCalls == 4)

        let allTimeBuckets = store.fetchUsageBreakdown(period: .allTime, usdToVndRate: rate, now: now)
        #expect(allTimeBuckets.map(\.label) == ["11/2025", "02/2026", "06/2026"])

        // Reset clears API usage
        store.resetAPIUsage()
        let cleared = store.fetchUsageSummary(period: .allTime, usdToVndRate: rate, now: now)
        #expect(cleared.apiCalls == 0)
        #expect(cleared.totalTokens == 0)
        #expect(store.fetchUsageBreakdown(period: .allTime, usdToVndRate: rate, now: now).isEmpty)
    }
}
