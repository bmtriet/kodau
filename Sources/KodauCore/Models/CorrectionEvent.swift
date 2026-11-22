import Foundation

/// Which user gesture produced a correction. Kept as a raw string so the local SQLite log stays readable and
/// stable when new sources are added.
public enum CorrectionAction: String, Codable, CaseIterable, Sendable {
    /// `⌥1..5` / popup click picked another diacritic form for the focused word.
    case candidatePick = "candidate_pick"
    /// `⌥E` retyped the focused word in place.
    case retype = "retype"
    /// `⌥Esc` reverted the whole composing clause to raw ASCII.
    case revertClause = "revert_clause"
    /// `⌥Esc` / popup undo rejected a Gemini change.
    case rejectGemini = "reject_gemini"
    /// Inline VNI digit override (`ban5` → `bạn`) inside Smart mode.
    case inlineVNI = "inline_vni"
    /// The user went back into already-committed text and fixed a word Kodau restored.
    case editAfterCommit = "edit_after_commit"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .candidatePick: return "Chọn từ khác"
        case .retype: return "Gõ lại từ"
        case .revertClause: return "Hoàn nguyên câu"
        case .rejectGemini: return "Từ chối sửa của Gemini"
        case .inlineVNI: return "VNI trong câu"
        case .editAfterCommit: return "Sửa sau khi đã gõ"
        }
    }
}

/// One local, on-device record of a diacritic correction the user made.
///
/// `rawClause`/`finalOutput` are the exact corpus pair Part 2 expects (`raw`/`expected`), so the "Lỗi hay gặp"
/// tab can export real mistakes as regression test lines.
public struct CorrectionEvent: Equatable, Sendable {
    /// SQLite row id; `nil` for an event that has not been stored yet.
    public var id: Int64?
    public var createdAt: Date
    /// Bundle id of the app the user was typing in, when the adapter could read it.
    public var appBundleID: String
    /// Raw ASCII clause as typed.
    public var rawClause: String
    /// Words committed before this clause (may be empty).
    public var context: String
    /// What the offline engine produced for the clause before the correction.
    public var localOutput: String
    /// What Gemini produced, when the correction rejected a Gemini change.
    public var geminiOutput: String?
    /// What the clause looked like after the user's correction.
    public var finalOutput: String
    public var action: CorrectionAction
    /// 0-based word index the correction targeted, when it targeted one word.
    public var wordIndex: Int?
    /// ASCII base form of the corrected word (e.g. `ban`).
    public var baseWord: String
    /// The surface Kodau had produced (e.g. `bán`).
    public var wrongSurface: String
    /// The surface the user wanted (e.g. `bạn`).
    public var rightSurface: String
    /// Where the correction was detected (`kodau-im`, `kodau-app`, `edit-after-commit`, …).
    public var source: String
    /// How sure the offline engine was, when known.
    public var confidence: Double?

    public init(
        id: Int64? = nil,
        createdAt: Date = Date(),
        appBundleID: String = "",
        rawClause: String,
        context: String = "",
        localOutput: String,
        geminiOutput: String? = nil,
        finalOutput: String,
        action: CorrectionAction,
        wordIndex: Int? = nil,
        baseWord: String = "",
        wrongSurface: String = "",
        rightSurface: String = "",
        source: String = "kodau-im",
        confidence: Double? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.appBundleID = appBundleID
        self.rawClause = rawClause
        self.context = context
        self.localOutput = localOutput
        self.geminiOutput = geminiOutput
        self.finalOutput = finalOutput
        self.action = action
        self.wordIndex = wordIndex
        self.baseWord = baseWord
        self.wrongSurface = wrongSurface
        self.rightSurface = rightSurface
        self.source = source
        self.confidence = confidence
    }
}

/// One row of the "Lỗi hay gặp" table: how often the same word mistake happened, plus the latest example.
public struct CorrectionMistake: Equatable, Sendable {
    public let baseWord: String
    public let wrongSurface: String
    public let rightSurface: String
    public let count: Int
    public let lastSeen: Date
    /// Raw clause of the most recent occurrence.
    public let exampleRawClause: String
    /// Committed context of the most recent occurrence.
    public let exampleContext: String

    public init(
        baseWord: String,
        wrongSurface: String,
        rightSurface: String,
        count: Int,
        lastSeen: Date,
        exampleRawClause: String,
        exampleContext: String = ""
    ) {
        self.baseWord = baseWord
        self.wrongSurface = wrongSurface
        self.rightSurface = rightSurface
        self.count = count
        self.lastSeen = lastSeen
        self.exampleRawClause = exampleRawClause
        self.exampleContext = exampleContext
    }

    /// The latest example clause, prefixed by its committed context when there is one.
    public var exampleSentence: String {
        [exampleContext, exampleRawClause]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " ")
    }
}
