import Foundation

/// Alternative diacritic suggestions for a specific word token in a converted clause.
public struct WordAlternative: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    /// 0-based word index in the tokenized clause.
    public let wordIndex: Int
    /// The ASCII / diacritic-less base token (lowercased).
    public let baseWord: String
    /// Currently selected output form.
    public let selected: String
    /// Ranked alternative candidates (including English/ASCII option if plausible).
    public let candidates: [String]

    public init(
        id: UUID = UUID(),
        wordIndex: Int,
        baseWord: String,
        selected: String,
        candidates: [String]
    ) {
        self.id = id
        self.wordIndex = wordIndex
        self.baseWord = baseWord
        self.selected = selected
        self.candidates = candidates
    }
}

/// Output of converting a typed text segment (word or clause).
public struct ConversionResult: Codable, Equatable, Sendable {
    /// Original raw text typed by the user.
    public let originalText: String
    /// Restored text with Vietnamese diacritics (and untouched English).
    public let convertedText: String
    /// Confidence score in [0.0, 1.0].
    public let confidence: Double
    /// Which engine produced the conversion.
    public let source: ConversionSource
    /// Detected language ratio: fraction of alphabetic tokens treated as Vietnamese [0.0, 1.0].
    public let vietnameseRatio: Double
    /// Alternative suggestions for ambiguous words (used by the Quick-Fix HUD & Playground).
    public let alternatives: [WordAlternative]
    /// Processing latency in milliseconds.
    public let latencyMs: Double
    /// Token usage & cost metadata when served by Gemini API (nil for offline local conversions).
    public let tokenUsage: TokenUsage?

    public var didChange: Bool {
        originalText != convertedText
    }

    public init(
        originalText: String,
        convertedText: String,
        confidence: Double,
        source: ConversionSource,
        vietnameseRatio: Double = 0,
        alternatives: [WordAlternative] = [],
        latencyMs: Double = 0,
        tokenUsage: TokenUsage? = nil
    ) {
        self.originalText = originalText
        self.convertedText = convertedText
        self.confidence = confidence
        self.source = source
        self.vietnameseRatio = vietnameseRatio
        self.alternatives = alternatives
        self.latencyMs = latencyMs
        self.tokenUsage = tokenUsage
    }
}

/// Token consumption recorded for a single Gemini API call.
public struct TokenUsage: Codable, Equatable, Sendable {
    public let model: String
    public let promptTokens: Int
    public let outputTokens: Int
    public let totalTokens: Int

    public init(model: String, promptTokens: Int, outputTokens: Int, totalTokens: Int? = nil) {
        self.model = model
        self.promptTokens = max(0, promptTokens)
        self.outputTokens = max(0, outputTokens)
        self.totalTokens = max(0, totalTokens ?? (promptTokens + outputTokens))
    }

    public func estimatedCostUSD() -> Double {
        let pricing = GeminiModelPricing.pricing(for: model)
        return (Double(promptTokens) / 1_000_000.0) * pricing.inputPerMillionUSD
            + (Double(outputTokens) / 1_000_000.0) * pricing.outputPerMillionUSD
    }

    public func estimatedCostVND(usdToVndRate: Double = 25_800) -> Double {
        estimatedCostUSD() * usdToVndRate
    }
}

/// Official pay-as-you-go pricing table (USD per 1M tokens) for Gemini models.
public struct GeminiModelPricing: Codable, Equatable, Identifiable, Sendable {
    public let modelID: String
    public let displayName: String
    public let inputPerMillionUSD: Double
    public let outputPerMillionUSD: Double
    public let cachedInputPerMillionUSD: Double
    public let note: String

    public var id: String { modelID }

    public init(
        modelID: String,
        displayName: String,
        inputPerMillionUSD: Double,
        outputPerMillionUSD: Double,
        cachedInputPerMillionUSD: Double = 0,
        note: String = ""
    ) {
        self.modelID = modelID
        self.displayName = displayName
        self.inputPerMillionUSD = inputPerMillionUSD
        self.outputPerMillionUSD = outputPerMillionUSD
        self.cachedInputPerMillionUSD = cachedInputPerMillionUSD
        self.note = note
    }

    public static let catalog: [GeminiModelPricing] = [
        GeminiModelPricing(
            modelID: "gemini-3.5-flash-lite",
            displayName: "Gemini 3.5 Flash-Lite",
            inputPerMillionUSD: 0.30,
            outputPerMillionUSD: 2.50,
            cachedInputPerMillionUSD: 0.03,
            note: "Mới nhất, thông minh cao (có Free Tier trên AI Studio)"
        ),
        GeminiModelPricing(
            modelID: "gemini-3.1-flash-lite",
            displayName: "Gemini 3.1 Flash-Lite",
            inputPerMillionUSD: 0.25,
            outputPerMillionUSD: 1.50,
            cachedInputPerMillionUSD: 0.025,
            note: "Cân bằng tốc độ và chi phí"
        ),
        GeminiModelPricing(
            modelID: "gemini-2.5-flash-lite",
            displayName: "Gemini 2.5 Flash-Lite",
            inputPerMillionUSD: 0.10,
            outputPerMillionUSD: 0.40,
            cachedInputPerMillionUSD: 0.01,
            note: "Siêu tiết kiệm (rẻ nhất cho gõ tiếng Việt hàng ngày)"
        ),
        GeminiModelPricing(
            modelID: "gemini-2.5-flash",
            displayName: "Gemini 2.5 Flash",
            inputPerMillionUSD: 0.30,
            outputPerMillionUSD: 2.50,
            cachedInputPerMillionUSD: 0.03,
            note: "Độ chính xác cao (bao gồm thinking tokens)"
        ),
        GeminiModelPricing(
            modelID: "gemini-2.0-flash",
            displayName: "Gemini 2.0 Flash",
            inputPerMillionUSD: 0.10,
            outputPerMillionUSD: 0.40,
            cachedInputPerMillionUSD: 0.025,
            note: "Nhanh, chi phí thấp"
        ),
        GeminiModelPricing(
            modelID: "gemini-1.5-flash",
            displayName: "Gemini 1.5 Flash",
            inputPerMillionUSD: 0.075,
            outputPerMillionUSD: 0.30,
            cachedInputPerMillionUSD: 0.01875,
            note: "Thế hệ cũ"
        )
    ]

    public static func pricing(for modelName: String) -> GeminiModelPricing {
        let lower = modelName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = catalog.first(where: { $0.modelID == lower }) {
            return exact
        }
        if lower.contains("3.5") && lower.contains("flash") {
            return catalog[0]
        }
        if lower.contains("3.1") && lower.contains("flash") {
            return catalog[1]
        }
        if lower.contains("2.5") && lower.contains("lite") {
            return catalog[2]
        }
        if lower.contains("2.5") && lower.contains("flash") {
            return catalog[3]
        }
        if lower.contains("2.0") && lower.contains("flash") {
            return catalog[4]
        }
        if lower.contains("1.5") && lower.contains("flash") {
            return catalog[5]
        }
        return catalog[0]
    }
}

/// Time aggregation period for API token & VND cost statistics.
public enum UsagePeriod: String, Codable, CaseIterable, Identifiable, Sendable {
    case day = "day"
    case week = "week"
    case month = "month"
    case year = "year"
    case allTime = "all_time"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .day: return "Hôm nay"
        case .week: return "Tuần này"
        case .month: return "Tháng này"
        case .year: return "Năm nay"
        case .allTime: return "Tất cả"
        }
    }
}

/// Aggregated API token and cost summary for a given period.
public struct UsageSummary: Codable, Equatable, Sendable {
    public let period: UsagePeriod
    public let apiCalls: Int
    public let promptTokens: Int
    public let outputTokens: Int
    public let totalTokens: Int
    public let costUSD: Double
    public let costVND: Double

    public init(
        period: UsagePeriod,
        apiCalls: Int = 0,
        promptTokens: Int = 0,
        outputTokens: Int = 0,
        totalTokens: Int = 0,
        costUSD: Double = 0,
        costVND: Double = 0
    ) {
        self.period = period
        self.apiCalls = apiCalls
        self.promptTokens = promptTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.costUSD = costUSD
        self.costVND = costVND
    }
}

/// Single time bucket (e.g., 1 day, 1 week, 1 month) for usage breakdown tables & charts.
public struct UsageBreakdownBucket: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let apiCalls: Int
    public let promptTokens: Int
    public let outputTokens: Int
    public let totalTokens: Int
    public let costUSD: Double
    public let costVND: Double

    public init(
        id: String,
        label: String,
        apiCalls: Int,
        promptTokens: Int,
        outputTokens: Int,
        totalTokens: Int,
        costUSD: Double,
        costVND: Double
    ) {
        self.id = id
        self.label = label
        self.apiCalls = apiCalls
        self.promptTokens = promptTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.costUSD = costUSD
        self.costVND = costVND
    }
}

/// A learned mapping entry exposed to the UI Dictionary & Training viewer.
public struct LearnedEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let baseWord: String
    public let surfaceForm: String
    public let prevContext: String
    public let count: Int
    public let userVerified: Bool
    public let isEnglish: Bool
    public let updatedAt: Date

    public init(
        id: String,
        baseWord: String,
        surfaceForm: String,
        prevContext: String = "",
        count: Int,
        userVerified: Bool,
        isEnglish: Bool,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.baseWord = baseWord
        self.surfaceForm = surfaceForm
        self.prevContext = prevContext
        self.count = count
        self.userVerified = userVerified
        self.isEnglish = isEnglish
        self.updatedAt = updatedAt
    }
}

/// A learned phrase/sentence example stored for exact recall and future model fine-tuning.
public struct LearnedPhrase: Codable, Equatable, Identifiable, Sendable {
    public let id: Int64
    public let rawNoDiacritics: String
    public let restoredText: String
    public let source: String
    public let userCorrected: Bool
    public let useCount: Int
    public let updatedAt: Date

    public init(
        id: Int64,
        rawNoDiacritics: String,
        restoredText: String,
        source: String,
        userCorrected: Bool,
        useCount: Int,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.rawNoDiacritics = rawNoDiacritics
        self.restoredText = restoredText
        self.source = source
        self.userCorrected = userCorrected
        self.useCount = useCount
        self.updatedAt = updatedAt
    }
}

/// Aggregate metrics tracking progress toward 100% API-free Offline Independence.
public struct LearningStats: Codable, Equatable, Sendable {
    public let totalConversions: Int
    public let localConversions: Int
    public let geminiConversions: Int
    public let userCorrections: Int
    public let uniqueWordsLearned: Int
    public let uniqueBigramsLearned: Int
    public let uniquePhrasesLearned: Int

    public var offlineHitRate: Double {
        guard totalConversions > 0 else { return 0.0 }
        return Double(localConversions) / Double(totalConversions)
    }

    /// Composite maturity score in [0.0, 1.0] combining vocabulary breadth, user guidance, and offline hit rate.
    public var independenceScore: Double {
        let vocabScore = min(1.0, Double(uniqueWordsLearned) / 400.0)
        let bigramScore = min(1.0, Double(uniqueBigramsLearned) / 800.0)
        let guideScore = min(1.0, Double(userCorrections) / 50.0)
        let hitScore = totalConversions >= 20 ? offlineHitRate : (offlineHitRate * Double(totalConversions) / 20.0)
        return min(1.0, vocabScore * 0.25 + bigramScore * 0.30 + guideScore * 0.15 + hitScore * 0.30)
    }

    public var stage: IndependenceStage {
        let score = independenceScore
        if score >= 0.85 && totalConversions >= 100 {
            return .independent
        } else if score >= 0.55 {
            return .proficient
        } else if score >= 0.20 || totalConversions >= 25 {
            return .learning
        } else {
            return .bootstrap
        }
    }

    public init(
        totalConversions: Int = 0,
        localConversions: Int = 0,
        geminiConversions: Int = 0,
        userCorrections: Int = 0,
        uniqueWordsLearned: Int = 0,
        uniqueBigramsLearned: Int = 0,
        uniquePhrasesLearned: Int = 0
    ) {
        self.totalConversions = totalConversions
        self.localConversions = localConversions
        self.geminiConversions = geminiConversions
        self.userCorrections = userCorrections
        self.uniqueWordsLearned = uniqueWordsLearned
        self.uniqueBigramsLearned = uniqueBigramsLearned
        self.uniquePhrasesLearned = uniquePhrasesLearned
    }
}
