import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum LearningStoreError: Error, LocalizedError, Sendable {
    case openFailed(String)
    case executionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let message):
            return "Failed to open Kodau SQLite database: \(message)"
        case .executionFailed(let message):
            return "SQLite execution error: \(message)"
        }
    }
}

/// Thread-safe SQLite3 personal language brain storing learned unigrams, bigrams,
/// trigrams, phrase memory, and offline-independence telemetry.
public final class LearningStore: @unchecked Sendable {
    public let databaseURL: URL

    private let queue = DispatchQueue(label: "com.kodau.learningstore.sqlite", qos: .userInitiated)
    private var db: OpaquePointer?

    private let generationLock = NSLock()
    private var _correctionGeneration: UInt64 = 0

    /// Monotonically increasing counter bumped whenever learned data the offline brain relies on changes
    /// (user corrections, dictionary deletions, full reset). Cached Gemini answers compare their recorded
    /// generation against this value so a stale cache entry can never shadow a newer correction.
    public var correctionGeneration: UInt64 {
        generationLock.lock()
        defer { generationLock.unlock() }
        return _correctionGeneration
    }

    private func bumpCorrectionGeneration() {
        generationLock.lock()
        _correctionGeneration &+= 1
        generationLock.unlock()
    }

    public init(databaseURL: URL = AppConfig.databaseFileURL) throws {
        self.databaseURL = databaseURL

        let isInMemory = databaseURL.path == ":memory:"
            || databaseURL.absoluteString == ":memory:"
            || databaseURL.lastPathComponent == ":memory:"

        let openPath: String
        if isInMemory {
            openPath = ":memory:"
        } else {
            let parentDir = databaseURL.deletingLastPathComponent()
            if !parentDir.path.isEmpty {
                try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }
            openPath = databaseURL.path
        }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(openPath, &handle, flags, nil)
        guard rc == SQLITE_OK, let openedDB = handle else {
            let message = handle.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "SQLite error code \(rc)"
            if let handle { sqlite3_close(handle) }
            throw LearningStoreError.openFailed(message)
        }

        self.db = openedDB
        try configureAndMigrate()
    }

    deinit {
        if let db {
            sqlite3_close_v2(db)
        }
    }

    // MARK: - Setup & Schema

    private func configureAndMigrate() throws {
        try queue.sync {
            try execLocked("PRAGMA journal_mode=WAL;")
            try execLocked("PRAGMA synchronous=NORMAL;")
            try execLocked("PRAGMA busy_timeout=3000;")

            try execLocked("""
                CREATE TABLE IF NOT EXISTS unigrams (
                    base_word TEXT NOT NULL,
                    surface TEXT NOT NULL,
                    count INTEGER NOT NULL DEFAULT 1,
                    user_verified INTEGER NOT NULL DEFAULT 0,
                    is_english INTEGER NOT NULL DEFAULT 0,
                    updated_at REAL NOT NULL,
                    PRIMARY KEY(base_word, surface)
                );
                """)

            try execLocked("""
                CREATE TABLE IF NOT EXISTS bigrams (
                    prev_surface TEXT NOT NULL,
                    base_word TEXT NOT NULL,
                    surface TEXT NOT NULL,
                    count INTEGER NOT NULL DEFAULT 1,
                    user_verified INTEGER NOT NULL DEFAULT 0,
                    updated_at REAL NOT NULL,
                    PRIMARY KEY(prev_surface, base_word, surface)
                );
                """)

            try execLocked("""
                CREATE TABLE IF NOT EXISTS trigrams (
                    prev2_surface TEXT NOT NULL,
                    prev1_surface TEXT NOT NULL,
                    base_word TEXT NOT NULL,
                    surface TEXT NOT NULL,
                    count INTEGER NOT NULL DEFAULT 1,
                    user_verified INTEGER NOT NULL DEFAULT 0,
                    updated_at REAL NOT NULL,
                    PRIMARY KEY(prev2_surface, prev1_surface, base_word, surface)
                );
                """)

            // Right-hand context: which surface the user wants for `base_word` when the NEXT word is `next_base`
            // (e.g. `ban` + next `hang` -> `bán`, `ban` + next `oi` -> `bạn`). Keyed by the next word's ASCII base
            // because the next word's diacritics are not decided yet while decoding left-to-right.
            try execLocked("""
                CREATE TABLE IF NOT EXISTS next_bigrams (
                    base_word TEXT NOT NULL,
                    surface TEXT NOT NULL,
                    next_base TEXT NOT NULL,
                    count INTEGER NOT NULL DEFAULT 1,
                    user_verified INTEGER NOT NULL DEFAULT 0,
                    updated_at REAL NOT NULL,
                    PRIMARY KEY(base_word, next_base, surface)
                );
                """)

            try execLocked("""
                CREATE TABLE IF NOT EXISTS phrases (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    raw_norm TEXT UNIQUE NOT NULL,
                    restored TEXT NOT NULL,
                    source TEXT NOT NULL,
                    user_corrected INTEGER NOT NULL DEFAULT 0,
                    use_count INTEGER NOT NULL DEFAULT 1,
                    updated_at REAL NOT NULL
                );
                """)

            try execLocked("""
                CREATE TABLE IF NOT EXISTS stats (
                    key TEXT PRIMARY KEY,
                    value INTEGER NOT NULL DEFAULT 0
                );
                """)

            try execLocked("""
                CREATE TABLE IF NOT EXISTS api_usage (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    timestamp REAL NOT NULL,
                    model TEXT NOT NULL,
                    prompt_tokens INTEGER NOT NULL,
                    output_tokens INTEGER NOT NULL,
                    total_tokens INTEGER NOT NULL,
                    cost_usd REAL NOT NULL,
                    cost_vnd REAL NOT NULL
                );
                """)

            try execLocked("CREATE INDEX IF NOT EXISTS idx_unigrams_base ON unigrams(base_word);")
            try execLocked("CREATE INDEX IF NOT EXISTS idx_bigrams_lookup ON bigrams(prev_surface, base_word);")
            try execLocked("CREATE INDEX IF NOT EXISTS idx_trigrams_lookup ON trigrams(prev2_surface, prev1_surface, base_word);")
            try execLocked("CREATE INDEX IF NOT EXISTS idx_next_bigrams_lookup ON next_bigrams(base_word, next_base);")
            try execLocked("CREATE INDEX IF NOT EXISTS idx_phrases_raw_norm ON phrases(raw_norm);")
            try execLocked("CREATE INDEX IF NOT EXISTS idx_api_usage_timestamp ON api_usage(timestamp);")
        }
    }

    // MARK: - Word-Identity Guards

    /// True when `surface` is `base` with (or without) Vietnamese diacritics, i.e. the same word.
    static func surface(_ surface: String, matchesBase base: String) -> Bool {
        VNIEngine.stripDiacritics(surface).lowercased() == VNIEngine.stripDiacritics(base).lowercased()
    }

    /// True when `corrected` is `raw` word-for-word, differing only in diacritics/casing.
    static func clause(_ corrected: String, matchesRawClause raw: String) -> Bool {
        let rawWords = TextSegmenter.wordTokens(from: raw)
        let correctedWords = TextSegmenter.wordTokens(from: corrected)
        guard rawWords.count == correctedWords.count else { return false }
        return zip(rawWords, correctedWords).allSatisfy { surface($1, matchesBase: $0) }
    }

    // MARK: - Learning APIs

    /// Pseudo-word used as left context for the first word of a sentence/clause, so even sentence-initial
    /// corrections are learned in context instead of as a global word replacement.
    public static let sentenceStartToken = "<s>"

    /// Learns from a finalized/accepted text (from Gemini, VNI typing, or imported corpus).
    /// Tokenizes words, strips diacritics to get base words, detects English vs Vietnamese tokens,
    /// updates unigrams, bigrams, trigrams, and phrase memory (for clauses of 2..16 words).
    public func learnFromText(_ text: String, source: String, userVerified: Bool = false) {
        let clauses = Self.splitIntoClauses(text)
        guard !clauses.isEmpty else { return }

        queue.sync {
            inTransactionLocked {
                for clause in clauses {
                    learnClauseLocked(clause, source: source, userVerified: userVerified)
                }
            }
        }
    }

    /// Internal helper used when learning a single word with preceding context (e.g. VNI mode).
    internal func learnWordWithContext(
        surface: String,
        prev1: String?,
        prev2: String?,
        userVerified: Bool
    ) {
        let cleanSurface = surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = VNIEngine.stripDiacritics(cleanSurface).lowercased()
        guard Self.isLearnableWord(base) else { return }

        let isEnglish = Self.detectTokenIsEnglish(rawToken: surface, lowerSurface: cleanSurface, baseWord: base, clauseHasVietnameseDiacritics: VNIEngine.containsVietnameseDiacritics(cleanSurface), clauseMajorityEnglish: false)
        let now = Date().timeIntervalSince1970

        queue.sync {
            inTransactionLocked {
                // Unigram = weak global prior only; the user's intent is recorded on the context n-grams below.
                upsertUnigramLocked(
                    baseWord: base,
                    surface: cleanSurface,
                    deltaCount: 1,
                    userVerified: false,
                    isEnglish: isEnglish,
                    timestamp: now
                )

                if let p1 = prev1?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !p1.isEmpty {
                    upsertBigramLocked(
                        prevSurface: p1,
                        baseWord: base,
                        surface: cleanSurface,
                        deltaCount: 1,
                        userVerified: userVerified,
                        timestamp: now
                    )

                    if let p2 = prev2?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !p2.isEmpty {
                        upsertTrigramLocked(
                            prev2Surface: p2,
                            prev1Surface: p1,
                            baseWord: base,
                            surface: cleanSurface,
                            deltaCount: 1,
                            userVerified: userVerified,
                            timestamp: now
                        )
                    }
                }
            }
        }
    }

    /// Records a user correction **in context** (not as a global replace rule).
    ///
    /// When the user fixes `baseWord` to `chosenSurface` (Vietnamese OR English) between `prev2 prev1 _ next1`,
    /// the strong, user-verified boost goes to the context n-grams (left bigram/trigram, right `next_bigrams`)
    /// so the same word in a different context keeps its own best form (`tôi bán hàng` vs `chào bạn`).
    /// The unigram only gets a small, unverified count so the global prior shifts gently.
    /// A missing `prev1` means the word starts the sentence/clause and is learned after `sentenceStartToken`.
    public func recordUserCorrection(
        baseWord: String,
        chosenSurface: String,
        prev1: String? = nil,
        prev2: String? = nil,
        next1: String? = nil,
        fullRawClause: String? = nil,
        fullCorrectedClause: String? = nil
    ) {
        let cleanBase = VNIEngine.stripDiacritics(baseWord)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let cleanSurface = chosenSurface
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !cleanBase.isEmpty, !cleanSurface.isEmpty else { return }
        // Corrections only ever change diacritics. A different word (abbreviation expansion, typo fix, model
        // rewrite) must not become a learned rule that silently rewrites what the user types.
        guard Self.surface(cleanSurface, matchesBase: cleanBase) else { return }

        let hasDiacritics = VNIEngine.containsVietnameseDiacritics(cleanSurface)
        let isEnglish: Bool
        if hasDiacritics {
            isEnglish = false
        } else if cleanSurface == cleanBase {
            let hint = VietnamesePhonology.classifyToken(chosenSurface)
            isEnglish = SeedLexicon.englishWords.contains(cleanBase)
                || !VietnamesePhonology.isValidVietnameseSyllable(cleanBase)
                || hint == .definiteEnglishOrCode
                || hint == .likelyEnglish
        } else {
            isEnglish = false
        }

        let now = Date().timeIntervalSince1970
        let boost = 5

        let trimmedPrev1 = prev1?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let contextPrev1 = trimmedPrev1.isEmpty ? Self.sentenceStartToken : trimmedPrev1
        let nextBase = next1.map { VNIEngine.stripDiacritics($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""

        queue.sync {
            inTransactionLocked {
                // Weak global prior only (no user_verified flag => never acts as a context-free replace rule).
                upsertUnigramLocked(
                    baseWord: cleanBase,
                    surface: cleanSurface,
                    deltaCount: 1,
                    userVerified: false,
                    isEnglish: isEnglish,
                    timestamp: now
                )

                if Self.isLearnableWord(nextBase) {
                    upsertNextBigramLocked(
                        baseWord: cleanBase,
                        surface: cleanSurface,
                        nextBase: nextBase,
                        deltaCount: boost,
                        userVerified: true,
                        timestamp: now
                    )
                }

                if case let p1Raw = contextPrev1, !p1Raw.isEmpty {
                    upsertBigramLocked(
                        prevSurface: p1Raw,
                        baseWord: cleanBase,
                        surface: cleanSurface,
                        deltaCount: boost,
                        userVerified: true,
                        timestamp: now
                    )

                    if let p2Raw = prev2?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !p2Raw.isEmpty {
                        upsertTrigramLocked(
                            prev2Surface: p2Raw,
                            prev1Surface: p1Raw,
                            baseWord: cleanBase,
                            surface: cleanSurface,
                            deltaCount: boost,
                            userVerified: true,
                            timestamp: now
                        )
                    }
                }

                if let rawClause = fullRawClause?.trimmingCharacters(in: .whitespacesAndNewlines),
                   let correctedClause = fullCorrectedClause?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !rawClause.isEmpty,
                   !correctedClause.isEmpty,
                   Self.clause(correctedClause, matchesRawClause: rawClause) {
                    let rawNorm = Self.normalizePhraseKey(rawClause)
                    if !rawNorm.isEmpty {
                        upsertPhraseLocked(
                            rawNorm: rawNorm,
                            restored: correctedClause,
                            source: "user_correction",
                            userCorrected: true,
                            timestamp: now
                        )
                    }
                }

                incrementStatLocked(key: "user_corrections", delta: 1)
            }
        }

        bumpCorrectionGeneration()
    }

    /// Records conversion telemetry for the Roadmap & Independence tracker.
    public func recordConversionEvent(source: ConversionSource) {
        queue.sync {
            inTransactionLocked {
                incrementStatLocked(key: "total_conversions", delta: 1)
                if source == .geminiAPI {
                    incrementStatLocked(key: "gemini_conversions", delta: 1)
                } else {
                    incrementStatLocked(key: "local_conversions", delta: 1)
                }
            }
        }
    }

    // MARK: - Lookup APIs

    /// Exact phrase lookup (case-insensitive normalized no-diacritics key).
    public func lookupPhrase(rawNoDiacritics: String) -> (restored: String, userCorrected: Bool, useCount: Int)? {
        let key = Self.normalizePhraseKey(rawNoDiacritics)
        guard !key.isEmpty else { return nil }

        return queue.sync {
            let sql = "SELECT restored, user_corrected, use_count FROM phrases WHERE raw_norm = ? LIMIT 1;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }

            bindText(stmt, index: 1, value: key)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

            let restored = columnText(stmt, index: 0)
            let userCorrected = sqlite3_column_int(stmt, 1) != 0
            let useCount = Int(sqlite3_column_int(stmt, 2))
            return (restored: restored, userCorrected: userCorrected, useCount: useCount)
        }
    }

    /// Lookup learned unigram candidates for `baseWord` (lowercased ASCII).
    public func unigramCandidates(for baseWord: String) -> [(surface: String, count: Int, userVerified: Bool, isEnglish: Bool)] {
        let key = VNIEngine.stripDiacritics(baseWord).lowercased()
        guard !key.isEmpty else { return [] }

        return queue.sync {
            let sql = """
                SELECT surface, count, user_verified, is_english
                FROM unigrams
                WHERE base_word = ?
                ORDER BY user_verified DESC, count DESC, updated_at DESC;
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            bindText(stmt, index: 1, value: key)
            var results: [(surface: String, count: Int, userVerified: Bool, isEnglish: Bool)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let surface = columnText(stmt, index: 0)
                let count = Int(sqlite3_column_int(stmt, 1))
                let userVerified = sqlite3_column_int(stmt, 2) != 0
                let isEnglish = sqlite3_column_int(stmt, 3) != 0
                results.append((surface: surface, count: count, userVerified: userVerified, isEnglish: isEnglish))
            }
            // A learned surface must be this base word with diacritics; never a different word (e.g. "ko" -> "không").
            return results.filter { Self.surface($0.surface, matchesBase: key) }
        }
    }

    /// Lookup learned bigram candidates given `prevSurface` (lowercased) and `baseWord` (lowercased ASCII).
    public func bigramCandidates(prevSurface: String, baseWord: String) -> [(surface: String, count: Int, userVerified: Bool)] {
        let prev = prevSurface.lowercased()
        let base = VNIEngine.stripDiacritics(baseWord).lowercased()
        guard !prev.isEmpty, !base.isEmpty else { return [] }

        return queue.sync {
            let sql = """
                SELECT surface, count, user_verified
                FROM bigrams
                WHERE prev_surface = ? AND base_word = ?
                ORDER BY user_verified DESC, count DESC, updated_at DESC;
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            bindText(stmt, index: 1, value: prev)
            bindText(stmt, index: 2, value: base)
            var results: [(surface: String, count: Int, userVerified: Bool)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let surface = columnText(stmt, index: 0)
                let count = Int(sqlite3_column_int(stmt, 1))
                let userVerified = sqlite3_column_int(stmt, 2) != 0
                results.append((surface: surface, count: count, userVerified: userVerified))
            }
            // A learned surface must be this base word with diacritics; never a different word (e.g. "ko" -> "không").
            return results.filter { Self.surface($0.surface, matchesBase: base) }
        }
    }

    /// Lookup learned trigram candidates given `prev2`, `prev1` (lowercased) and `baseWord`.
    public func trigramCandidates(prev2: String, prev1: String, baseWord: String) -> [(surface: String, count: Int, userVerified: Bool)] {
        let p2 = prev2.lowercased()
        let p1 = prev1.lowercased()
        let base = VNIEngine.stripDiacritics(baseWord).lowercased()
        guard !p2.isEmpty, !p1.isEmpty, !base.isEmpty else { return [] }

        return queue.sync {
            let sql = """
                SELECT surface, count, user_verified
                FROM trigrams
                WHERE prev2_surface = ? AND prev1_surface = ? AND base_word = ?
                ORDER BY user_verified DESC, count DESC, updated_at DESC;
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            bindText(stmt, index: 1, value: p2)
            bindText(stmt, index: 2, value: p1)
            bindText(stmt, index: 3, value: base)
            var results: [(surface: String, count: Int, userVerified: Bool)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let surface = columnText(stmt, index: 0)
                let count = Int(sqlite3_column_int(stmt, 1))
                let userVerified = sqlite3_column_int(stmt, 2) != 0
                results.append((surface: surface, count: count, userVerified: userVerified))
            }
            // A learned surface must be this base word with diacritics; never a different word (e.g. "ko" -> "không").
            return results.filter { Self.surface($0.surface, matchesBase: base) }
        }
    }

    /// Lookup learned right-context candidates: surfaces chosen for `baseWord` when followed by a word whose
    /// ASCII base is `nextBase`.
    public func nextBigramCandidates(baseWord: String, nextBase: String) -> [(surface: String, count: Int, userVerified: Bool)] {
        let base = VNIEngine.stripDiacritics(baseWord).lowercased()
        let next = VNIEngine.stripDiacritics(nextBase).lowercased()
        guard !base.isEmpty, !next.isEmpty else { return [] }

        return queue.sync {
            let sql = """
                SELECT surface, count, user_verified
                FROM next_bigrams
                WHERE base_word = ? AND next_base = ?
                ORDER BY user_verified DESC, count DESC, updated_at DESC;
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            bindText(stmt, index: 1, value: base)
            bindText(stmt, index: 2, value: next)
            var results: [(surface: String, count: Int, userVerified: Bool)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append((
                    surface: columnText(stmt, index: 0),
                    count: Int(sqlite3_column_int(stmt, 1)),
                    userVerified: sqlite3_column_int(stmt, 2) != 0
                ))
            }
            // A learned surface must be this base word with diacritics; never a different word (e.g. "ko" -> "không").
            return results.filter { Self.surface($0.surface, matchesBase: base) }
        }
    }

    // MARK: - Corpus Import & Dictionary Management

    /// Imports a block of Vietnamese/English text (split by lines/sentences) to bootstrap the personal brain.
    /// Returns number of sentences imported.
    @discardableResult
    public func importCorpus(_ text: String) -> Int {
        let sentences = Self.splitIntoClauses(text)
        guard !sentences.isEmpty else { return 0 }

        var importedCount = 0
        queue.sync {
            inTransactionLocked {
                for sentence in sentences {
                    if learnClauseLocked(sentence, source: "import", userVerified: false) {
                        importedCount += 1
                    }
                }
            }
        }
        return importedCount
    }

    /// Lists learned entries for the Dictionary UI (with optional search filter).
    public func fetchLearnedEntries(search: String = "", limit: Int = 200) -> [LearnedEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let safeLimit = max(1, limit)

        return queue.sync {
            var stmt: OpaquePointer?
            if query.isEmpty {
                let sql = """
                    SELECT base_word, surface, count, user_verified, is_english, updated_at
                    FROM unigrams
                    ORDER BY user_verified DESC, count DESC, updated_at DESC
                    LIMIT ?;
                    """
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
                sqlite3_bind_int(stmt, 1, Int32(safeLimit))
            } else {
                let strippedQuery = VNIEngine.stripDiacritics(query).lowercased()
                let sql = """
                    SELECT base_word, surface, count, user_verified, is_english, updated_at
                    FROM unigrams
                    WHERE base_word LIKE ? OR surface LIKE ?
                    ORDER BY user_verified DESC, count DESC, updated_at DESC
                    LIMIT ?;
                    """
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
                bindText(stmt, index: 1, value: "%\(strippedQuery)%")
                bindText(stmt, index: 2, value: "%\(query)%")
                sqlite3_bind_int(stmt, 3, Int32(safeLimit))
            }
            defer { sqlite3_finalize(stmt) }

            var entries: [LearnedEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let baseWord = columnText(stmt, index: 0)
                let surfaceForm = columnText(stmt, index: 1)
                let count = Int(sqlite3_column_int(stmt, 2))
                let userVerified = sqlite3_column_int(stmt, 3) != 0
                let isEnglish = sqlite3_column_int(stmt, 4) != 0
                let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
                entries.append(
                    LearnedEntry(
                        id: "\(baseWord)::\(surfaceForm)",
                        baseWord: baseWord,
                        surfaceForm: surfaceForm,
                        prevContext: "",
                        count: count,
                        userVerified: userVerified,
                        isEnglish: isEnglish,
                        updatedAt: updatedAt
                    )
                )
            }
            return entries
        }
    }

    /// Lists learned phrases for the Dictionary UI.
    public func fetchLearnedPhrases(search: String = "", limit: Int = 100) -> [LearnedPhrase] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let safeLimit = max(1, limit)

        return queue.sync {
            var stmt: OpaquePointer?
            if query.isEmpty {
                let sql = """
                    SELECT id, raw_norm, restored, source, user_corrected, use_count, updated_at
                    FROM phrases
                    ORDER BY user_corrected DESC, use_count DESC, updated_at DESC
                    LIMIT ?;
                    """
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
                sqlite3_bind_int(stmt, 1, Int32(safeLimit))
            } else {
                let strippedQuery = VNIEngine.stripDiacritics(query).lowercased()
                let sql = """
                    SELECT id, raw_norm, restored, source, user_corrected, use_count, updated_at
                    FROM phrases
                    WHERE raw_norm LIKE ? OR restored LIKE ?
                    ORDER BY user_corrected DESC, use_count DESC, updated_at DESC
                    LIMIT ?;
                    """
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
                bindText(stmt, index: 1, value: "%\(strippedQuery)%")
                bindText(stmt, index: 2, value: "%\(query)%")
                sqlite3_bind_int(stmt, 3, Int32(safeLimit))
            }
            defer { sqlite3_finalize(stmt) }

            var phrases: [LearnedPhrase] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let rawNorm = columnText(stmt, index: 1)
                let restored = columnText(stmt, index: 2)
                let source = columnText(stmt, index: 3)
                let userCorrected = sqlite3_column_int(stmt, 4) != 0
                let useCount = Int(sqlite3_column_int(stmt, 5))
                let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
                phrases.append(
                    LearnedPhrase(
                        id: id,
                        rawNoDiacritics: rawNorm,
                        restoredText: restored,
                        source: source,
                        userCorrected: userCorrected,
                        useCount: useCount,
                        updatedAt: updatedAt
                    )
                )
            }
            return phrases
        }
    }

    /// Deletes a specific unigram entry (and matching bigram/trigram targets).
    public func deleteEntry(baseWord: String, surfaceForm: String) {
        let base = VNIEngine.stripDiacritics(baseWord).lowercased()
        let surface = surfaceForm.lowercased()
        queue.sync {
            inTransactionLocked {
                deleteWithTwoParamsLocked(
                    sql: "DELETE FROM unigrams WHERE base_word = ? AND surface = ?;",
                    p1: base,
                    p2: surface
                )
                deleteWithTwoParamsLocked(
                    sql: "DELETE FROM bigrams WHERE base_word = ? AND surface = ?;",
                    p1: base,
                    p2: surface
                )
                deleteWithTwoParamsLocked(
                    sql: "DELETE FROM trigrams WHERE base_word = ? AND surface = ?;",
                    p1: base,
                    p2: surface
                )
                deleteWithTwoParamsLocked(
                    sql: "DELETE FROM next_bigrams WHERE base_word = ? AND surface = ?;",
                    p1: base,
                    p2: surface
                )
            }
        }

        bumpCorrectionGeneration()
    }

    /// Deletes a specific phrase by ID.
    public func deletePhrase(id: Int64) {
        queue.sync {
            let sql = "DELETE FROM phrases WHERE id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, id)
            sqlite3_step(stmt)
        }

        bumpCorrectionGeneration()
    }

    /// Returns aggregate learning & independence metrics.
    public func fetchStats() -> LearningStats {
        queue.sync {
            var statMap: [String: Int] = [:]
            do {
                let sql = "SELECT key, value FROM stats;"
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    defer { sqlite3_finalize(stmt) }
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        let key = columnText(stmt, index: 0)
                        let value = Int(sqlite3_column_int64(stmt, 1))
                        statMap[key] = value
                    }
                }
            }

            let uniqueWords = scalarCountLocked("SELECT COUNT(DISTINCT base_word) FROM unigrams;")
            let uniqueBigrams = scalarCountLocked("SELECT COUNT(*) FROM bigrams;")
            let uniquePhrases = scalarCountLocked("SELECT COUNT(*) FROM phrases;")

            return LearningStats(
                totalConversions: statMap["total_conversions", default: 0],
                localConversions: statMap["local_conversions", default: 0],
                geminiConversions: statMap["gemini_conversions", default: 0],
                userCorrections: statMap["user_corrections", default: 0],
                uniqueWordsLearned: uniqueWords,
                uniqueBigramsLearned: uniqueBigrams,
                uniquePhrasesLearned: uniquePhrases
            )
        }
    }

    /// Exports all learned phrases & user corrections as JSONL (compatible with Gemini / LoRA fine-tuning format).
    public func exportDatasetJSONL() -> String {
        queue.sync {
            var lines: [String] = []
            var seenInputs = Set<String>()

            // 1. Export all learned phrases (user corrections first)
            let phraseSQL = """
                SELECT raw_norm, restored, source, user_corrected, use_count
                FROM phrases
                ORDER BY user_corrected DESC, use_count DESC, updated_at DESC;
                """
            var phraseStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, phraseSQL, -1, &phraseStmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(phraseStmt) }
                while sqlite3_step(phraseStmt) == SQLITE_ROW {
                    let rawNorm = columnText(phraseStmt, index: 0)
                    let restored = columnText(phraseStmt, index: 1)
                    let source = columnText(phraseStmt, index: 2)
                    let userCorrected = sqlite3_column_int(phraseStmt, 3) != 0
                    let useCount = Int(sqlite3_column_int(phraseStmt, 4))
                    if seenInputs.insert(rawNorm).inserted,
                       let jsonLine = Self.formatFineTuneJSONLine(
                        input: rawNorm,
                        output: restored,
                        source: source,
                        userCorrected: userCorrected,
                        useCount: useCount
                       ) {
                        lines.append(jsonLine)
                    }
                }
            }

            // 2. Export user-verified bigram corrections not already represented
            let bigramSQL = """
                SELECT prev_surface, base_word, surface, count
                FROM bigrams
                WHERE user_verified = 1
                ORDER BY count DESC, updated_at DESC;
                """
            var bigramStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, bigramSQL, -1, &bigramStmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(bigramStmt) }
                while sqlite3_step(bigramStmt) == SQLITE_ROW {
                    let prevSurface = columnText(bigramStmt, index: 0)
                    let baseWord = columnText(bigramStmt, index: 1)
                    let surface = columnText(bigramStmt, index: 2)
                    let count = Int(sqlite3_column_int(bigramStmt, 3))
                    let rawPair = "\(VNIEngine.stripDiacritics(prevSurface).lowercased()) \(baseWord)"
                    let restoredPair = "\(prevSurface) \(surface)"
                    if seenInputs.insert(rawPair).inserted,
                       let jsonLine = Self.formatFineTuneJSONLine(
                        input: rawPair,
                        output: restoredPair,
                        source: "user_correction_bigram",
                        userCorrected: true,
                        useCount: count
                       ) {
                        lines.append(jsonLine)
                    }
                }
            }

            // 3. Export standalone user-verified unigram corrections
            let unigramSQL = """
                SELECT base_word, surface, count
                FROM unigrams
                WHERE user_verified = 1
                ORDER BY count DESC, updated_at DESC;
                """
            var unigramStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, unigramSQL, -1, &unigramStmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(unigramStmt) }
                while sqlite3_step(unigramStmt) == SQLITE_ROW {
                    let baseWord = columnText(unigramStmt, index: 0)
                    let surface = columnText(unigramStmt, index: 1)
                    let count = Int(sqlite3_column_int(unigramStmt, 2))
                    if seenInputs.insert(baseWord).inserted,
                       let jsonLine = Self.formatFineTuneJSONLine(
                        input: baseWord,
                        output: surface,
                        source: "user_correction_word",
                        userCorrected: true,
                        useCount: count
                       ) {
                        lines.append(jsonLine)
                    }
                }
            }

            return lines.joined(separator: "\n")
        }
    }

    /// Resets all learned data.
    public func resetAllData() {
        queue.sync {
            inTransactionLocked {
                _ = try? execLocked("DELETE FROM unigrams;")
                _ = try? execLocked("DELETE FROM bigrams;")
                _ = try? execLocked("DELETE FROM trigrams;")
                _ = try? execLocked("DELETE FROM next_bigrams;")
                _ = try? execLocked("DELETE FROM phrases;")
                _ = try? execLocked("DELETE FROM stats;")
            }
        }

        bumpCorrectionGeneration()
    }

    // MARK: - API Usage & Cost Telemetry

    /// Records token consumption and estimated USD/VND cost for a Gemini API call.
    public func recordAPIUsage(_ usage: TokenUsage, usdToVndRate: Double = 25_800, timestamp: Date = Date()) {
        let costUSD = usage.estimatedCostUSD()
        let costVND = costUSD * usdToVndRate
        let ts = timestamp.timeIntervalSince1970

        queue.sync {
            let sql = """
                INSERT INTO api_usage (timestamp, model, prompt_tokens, output_tokens, total_tokens, cost_usd, cost_vnd)
                VALUES (?, ?, ?, ?, ?, ?, ?);
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_double(stmt, 1, ts)
            bindText(stmt, index: 2, value: usage.model)
            sqlite3_bind_int64(stmt, 3, Int64(usage.promptTokens))
            sqlite3_bind_int64(stmt, 4, Int64(usage.outputTokens))
            sqlite3_bind_int64(stmt, 5, Int64(usage.totalTokens))
            sqlite3_bind_double(stmt, 6, costUSD)
            sqlite3_bind_double(stmt, 7, costVND)
            sqlite3_step(stmt)
        }
    }

    /// Returns aggregated token & cost totals for the specified period, computing VND dynamically from `usdToVndRate`.
    public func fetchUsageSummary(
        period: UsagePeriod,
        usdToVndRate: Double = 25_800,
        now: Date = Date()
    ) -> UsageSummary {
        queue.sync {
            fetchUsageSummaryLocked(period: period, usdToVndRate: usdToVndRate, now: now)
        }
    }

    /// Returns aggregated usage summaries for all periods (`.day`, `.week`, `.month`, `.year`, `.allTime`).
    public func fetchAllPeriodSummaries(
        usdToVndRate: Double = 25_800,
        now: Date = Date()
    ) -> [UsageSummary] {
        queue.sync {
            UsagePeriod.allCases.map { period in
                fetchUsageSummaryLocked(period: period, usdToVndRate: usdToVndRate, now: now)
            }
        }
    }

    /// Returns chronologically ordered time buckets breaking down API usage within `period`.
    public func fetchUsageBreakdown(
        period: UsagePeriod,
        usdToVndRate: Double = 25_800,
        now: Date = Date()
    ) -> [UsageBreakdownBucket] {
        queue.sync {
            let sql: String
            let startTs: Double?
            if period == .allTime {
                sql = """
                    SELECT timestamp, prompt_tokens, output_tokens, total_tokens, cost_usd
                    FROM api_usage
                    ORDER BY timestamp ASC;
                    """
                startTs = nil
            } else {
                sql = """
                    SELECT timestamp, prompt_tokens, output_tokens, total_tokens, cost_usd
                    FROM api_usage
                    WHERE timestamp >= ?
                    ORDER BY timestamp ASC;
                    """
                startTs = Self.periodStartTimestamp(for: period, now: now)
            }

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            if let startTs {
                sqlite3_bind_double(stmt, 1, startTs)
            }

            struct Accumulator {
                let id: String
                let label: String
                var apiCalls: Int = 0
                var promptTokens: Int = 0
                var outputTokens: Int = 0
                var totalTokens: Int = 0
                var costUSD: Double = 0
            }

            let calendar = Calendar.current
            var bucketsByID: [String: Accumulator] = [:]

            while sqlite3_step(stmt) == SQLITE_ROW {
                let ts = sqlite3_column_double(stmt, 0)
                let promptTokens = Int(sqlite3_column_int64(stmt, 1))
                let outputTokens = Int(sqlite3_column_int64(stmt, 2))
                let totalTokens = Int(sqlite3_column_int64(stmt, 3))
                let costUSD = sqlite3_column_double(stmt, 4)

                let date = Date(timeIntervalSince1970: ts)
                let comps = calendar.dateComponents([.year, .month, .day, .hour], from: date)
                let year = comps.year ?? 1970
                let month = comps.month ?? 1
                let day = comps.day ?? 1
                let hour = comps.hour ?? 0

                let bucketID: String
                let label: String
                switch period {
                case .day:
                    bucketID = String(format: "%04d-%02d-%02d-%02d", year, month, day, hour)
                    label = String(format: "%02dh", hour)
                case .week, .month:
                    bucketID = String(format: "%04d-%02d-%02d", year, month, day)
                    label = String(format: "%02d/%02d", day, month)
                case .year:
                    bucketID = String(format: "%04d-%02d", year, month)
                    label = "T\(month)/\(year)"
                case .allTime:
                    bucketID = String(format: "%04d-%02d", year, month)
                    label = String(format: "%02d/%04d", month, year)
                }

                var acc = bucketsByID[bucketID] ?? Accumulator(id: bucketID, label: label)
                acc.apiCalls += 1
                acc.promptTokens += promptTokens
                acc.outputTokens += outputTokens
                acc.totalTokens += totalTokens
                acc.costUSD += costUSD
                bucketsByID[bucketID] = acc
            }

            return bucketsByID.values
                .sorted { $0.id < $1.id }
                .map { acc in
                    UsageBreakdownBucket(
                        id: acc.id,
                        label: acc.label,
                        apiCalls: acc.apiCalls,
                        promptTokens: acc.promptTokens,
                        outputTokens: acc.outputTokens,
                        totalTokens: acc.totalTokens,
                        costUSD: acc.costUSD,
                        costVND: acc.costUSD * usdToVndRate
                    )
                }
        }
    }

    /// Clears all recorded API token & cost history.
    public func resetAPIUsage() {
        queue.sync {
            _ = try? execLocked("DELETE FROM api_usage;")
        }
    }

    private func fetchUsageSummaryLocked(
        period: UsagePeriod,
        usdToVndRate: Double,
        now: Date
    ) -> UsageSummary {
        let sql: String
        let startTs: Double?
        if period == .allTime {
            sql = """
                SELECT COUNT(*), COALESCE(SUM(prompt_tokens), 0), COALESCE(SUM(output_tokens), 0),
                       COALESCE(SUM(total_tokens), 0), COALESCE(SUM(cost_usd), 0.0)
                FROM api_usage;
                """
            startTs = nil
        } else {
            sql = """
                SELECT COUNT(*), COALESCE(SUM(prompt_tokens), 0), COALESCE(SUM(output_tokens), 0),
                       COALESCE(SUM(total_tokens), 0), COALESCE(SUM(cost_usd), 0.0)
                FROM api_usage
                WHERE timestamp >= ?;
                """
            startTs = Self.periodStartTimestamp(for: period, now: now)
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return UsageSummary(period: period)
        }
        defer { sqlite3_finalize(stmt) }

        if let startTs {
            sqlite3_bind_double(stmt, 1, startTs)
        }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return UsageSummary(period: period)
        }

        let apiCalls = Int(sqlite3_column_int64(stmt, 0))
        let promptTokens = Int(sqlite3_column_int64(stmt, 1))
        let outputTokens = Int(sqlite3_column_int64(stmt, 2))
        let totalTokens = Int(sqlite3_column_int64(stmt, 3))
        let costUSD = sqlite3_column_double(stmt, 4)
        let costVND = costUSD * usdToVndRate

        return UsageSummary(
            period: period,
            apiCalls: apiCalls,
            promptTokens: promptTokens,
            outputTokens: outputTokens,
            totalTokens: totalTokens,
            costUSD: costUSD,
            costVND: costVND
        )
    }

    private static func periodStartTimestamp(for period: UsagePeriod, now: Date) -> Double {
        let calendar = Calendar.current
        switch period {
        case .day:
            return calendar.startOfDay(for: now).timeIntervalSince1970
        case .week:
            let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start
                ?? calendar.startOfDay(for: now)
            return start.timeIntervalSince1970
        case .month:
            let start = calendar.dateInterval(of: .month, for: now)?.start
                ?? calendar.startOfDay(for: now)
            return start.timeIntervalSince1970
        case .year:
            let start = calendar.dateInterval(of: .year, for: now)?.start
                ?? calendar.startOfDay(for: now)
            return start.timeIntervalSince1970
        case .allTime:
            return 0
        }
    }

    // MARK: - Internal Locked SQL Operations

    @discardableResult
    private func learnClauseLocked(_ clause: String, source: String, userVerified: Bool) -> Bool {
        let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let tokens = Self.extractWordTokens(trimmed)
        guard !tokens.isEmpty else { return false }

        let hasVietnameseDiacritics = tokens.contains { VNIEngine.containsVietnameseDiacritics($0) }
        var englishSignalCount = 0
        var vietnameseSignalCount = 0
        for token in tokens {
            if VNIEngine.containsVietnameseDiacritics(token) {
                vietnameseSignalCount += 2
            } else {
                switch VietnamesePhonology.classifyToken(token) {
                case .definiteEnglishOrCode, .likelyEnglish:
                    englishSignalCount += 1
                case .definiteVietnamese, .likelyVietnamese:
                    vietnameseSignalCount += 1
                case .ambiguous:
                    break
                }
            }
        }
        let clauseMajorityEnglish = !hasVietnameseDiacritics && englishSignalCount > vietnameseSignalCount
        let now = Date().timeIntervalSince1970

        var prev2: String?
        var prev1: String? = Self.sentenceStartToken
        var learnableWordCount = 0
        // (base, surface) of the previous learnable word, to record right-hand context for it.
        var previousLearnable: (base: String, surface: String)?

        for rawToken in tokens {
            if VietnamesePhonology.isCodeOrTechnicalToken(rawToken) {
                prev2 = prev1
                prev1 = rawToken.lowercased()
                continue
            }

            let surface = rawToken.lowercased()
            let base = VNIEngine.stripDiacritics(surface).lowercased()
            guard Self.isLearnableWord(base) else {
                prev2 = nil
                prev1 = nil
                previousLearnable = nil
                continue
            }

            if let previous = previousLearnable {
                upsertNextBigramLocked(
                    baseWord: previous.base,
                    surface: previous.surface,
                    nextBase: base,
                    deltaCount: 1,
                    userVerified: userVerified,
                    timestamp: now
                )
            }
            previousLearnable = (base, surface)

            learnableWordCount += 1
            let isEnglish = Self.detectTokenIsEnglish(
                rawToken: rawToken,
                lowerSurface: surface,
                baseWord: base,
                clauseHasVietnameseDiacritics: hasVietnameseDiacritics,
                clauseMajorityEnglish: clauseMajorityEnglish
            )

            // Unigram = weak global prior; verified intent lives on the context n-grams.
            upsertUnigramLocked(
                baseWord: base,
                surface: surface,
                deltaCount: 1,
                userVerified: false,
                isEnglish: isEnglish,
                timestamp: now
            )

            if let p1 = prev1 {
                upsertBigramLocked(
                    prevSurface: p1,
                    baseWord: base,
                    surface: surface,
                    deltaCount: 1,
                    userVerified: userVerified,
                    timestamp: now
                )
            }

            if let p2 = prev2, let p1 = prev1 {
                upsertTrigramLocked(
                    prev2Surface: p2,
                    prev1Surface: p1,
                    baseWord: base,
                    surface: surface,
                    deltaCount: 1,
                    userVerified: userVerified,
                    timestamp: now
                )
            }

            prev2 = prev1
            prev1 = surface
        }

        if tokens.count >= 2 && tokens.count <= 16 {
            let rawNorm = Self.normalizePhraseKey(trimmed)
            if !rawNorm.isEmpty {
                upsertPhraseLocked(
                    rawNorm: rawNorm,
                    restored: trimmed,
                    source: source,
                    userCorrected: userVerified,
                    timestamp: now
                )
            }
        }

        return learnableWordCount > 0
    }

    private func upsertUnigramLocked(
        baseWord: String,
        surface: String,
        deltaCount: Int,
        userVerified: Bool,
        isEnglish: Bool,
        timestamp: Double
    ) {
        let sql = """
            INSERT INTO unigrams (base_word, surface, count, user_verified, is_english, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(base_word, surface) DO UPDATE SET
                count = unigrams.count + excluded.count,
                user_verified = MAX(unigrams.user_verified, excluded.user_verified),
                is_english = CASE WHEN excluded.user_verified = 1 THEN excluded.is_english ELSE unigrams.is_english END,
                updated_at = excluded.updated_at;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, index: 1, value: baseWord)
        bindText(stmt, index: 2, value: surface)
        sqlite3_bind_int(stmt, 3, Int32(deltaCount))
        sqlite3_bind_int(stmt, 4, userVerified ? 1 : 0)
        sqlite3_bind_int(stmt, 5, isEnglish ? 1 : 0)
        sqlite3_bind_double(stmt, 6, timestamp)
        sqlite3_step(stmt)
    }

    private func upsertBigramLocked(
        prevSurface: String,
        baseWord: String,
        surface: String,
        deltaCount: Int,
        userVerified: Bool,
        timestamp: Double
    ) {
        let sql = """
            INSERT INTO bigrams (prev_surface, base_word, surface, count, user_verified, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(prev_surface, base_word, surface) DO UPDATE SET
                count = bigrams.count + excluded.count,
                user_verified = MAX(bigrams.user_verified, excluded.user_verified),
                updated_at = excluded.updated_at;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, index: 1, value: prevSurface)
        bindText(stmt, index: 2, value: baseWord)
        bindText(stmt, index: 3, value: surface)
        sqlite3_bind_int(stmt, 4, Int32(deltaCount))
        sqlite3_bind_int(stmt, 5, userVerified ? 1 : 0)
        sqlite3_bind_double(stmt, 6, timestamp)
        sqlite3_step(stmt)
    }

    private func upsertNextBigramLocked(
        baseWord: String,
        surface: String,
        nextBase: String,
        deltaCount: Int,
        userVerified: Bool,
        timestamp: Double
    ) {
        let sql = """
            INSERT INTO next_bigrams (base_word, surface, next_base, count, user_verified, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(base_word, next_base, surface) DO UPDATE SET
                count = next_bigrams.count + excluded.count,
                user_verified = MAX(next_bigrams.user_verified, excluded.user_verified),
                updated_at = excluded.updated_at;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, index: 1, value: baseWord)
        bindText(stmt, index: 2, value: surface)
        bindText(stmt, index: 3, value: nextBase)
        sqlite3_bind_int(stmt, 4, Int32(deltaCount))
        sqlite3_bind_int(stmt, 5, userVerified ? 1 : 0)
        sqlite3_bind_double(stmt, 6, timestamp)
        sqlite3_step(stmt)
    }

    private func upsertTrigramLocked(
        prev2Surface: String,
        prev1Surface: String,
        baseWord: String,
        surface: String,
        deltaCount: Int,
        userVerified: Bool,
        timestamp: Double
    ) {
        let sql = """
            INSERT INTO trigrams (prev2_surface, prev1_surface, base_word, surface, count, user_verified, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(prev2_surface, prev1_surface, base_word, surface) DO UPDATE SET
                count = trigrams.count + excluded.count,
                user_verified = MAX(trigrams.user_verified, excluded.user_verified),
                updated_at = excluded.updated_at;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, index: 1, value: prev2Surface)
        bindText(stmt, index: 2, value: prev1Surface)
        bindText(stmt, index: 3, value: baseWord)
        bindText(stmt, index: 4, value: surface)
        sqlite3_bind_int(stmt, 5, Int32(deltaCount))
        sqlite3_bind_int(stmt, 6, userVerified ? 1 : 0)
        sqlite3_bind_double(stmt, 7, timestamp)
        sqlite3_step(stmt)
    }

    private func upsertPhraseLocked(
        rawNorm: String,
        restored: String,
        source: String,
        userCorrected: Bool,
        timestamp: Double
    ) {
        let sql = """
            INSERT INTO phrases (raw_norm, restored, source, user_corrected, use_count, updated_at)
            VALUES (?, ?, ?, ?, 1, ?)
            ON CONFLICT(raw_norm) DO UPDATE SET
                restored = CASE
                    WHEN excluded.user_corrected = 1 OR phrases.user_corrected = 0
                    THEN excluded.restored
                    ELSE phrases.restored
                END,
                source = CASE
                    WHEN excluded.user_corrected = 1 OR phrases.user_corrected = 0
                    THEN excluded.source
                    ELSE phrases.source
                END,
                user_corrected = MAX(phrases.user_corrected, excluded.user_corrected),
                use_count = phrases.use_count + 1,
                updated_at = excluded.updated_at;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, index: 1, value: rawNorm)
        bindText(stmt, index: 2, value: restored)
        bindText(stmt, index: 3, value: source)
        sqlite3_bind_int(stmt, 4, userCorrected ? 1 : 0)
        sqlite3_bind_double(stmt, 5, timestamp)
        sqlite3_step(stmt)
    }

    private func incrementStatLocked(key: String, delta: Int) {
        let sql = """
            INSERT INTO stats (key, value)
            VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET
                value = stats.value + excluded.value;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, index: 1, value: key)
        sqlite3_bind_int64(stmt, 2, Int64(delta))
        sqlite3_step(stmt)
    }

    private func deleteWithTwoParamsLocked(sql: String, p1: String, p2: String) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: p1)
        bindText(stmt, index: 2, value: p2)
        sqlite3_step(stmt)
    }

    private func scalarCountLocked(_ sql: String) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func inTransactionLocked(_ body: () -> Void) {
        _ = try? execLocked("BEGIN IMMEDIATE;")
        body()
        _ = try? execLocked("COMMIT;")
    }

    private func execLocked(_ sql: String) throws {
        var errorPtr: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errorPtr)
        if rc != SQLITE_OK {
            let message = errorPtr.map { String(cString: $0) } ?? "SQLite error \(rc)"
            if let errorPtr { sqlite3_free(errorPtr) }
            throw LearningStoreError.executionFailed(message)
        }
    }

    private func bindText(_ stmt: OpaquePointer?, index: Int32, value: String) {
        sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
    }

    private func columnText(_ stmt: OpaquePointer?, index: Int32) -> String {
        guard let cString = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cString)
    }

    // MARK: - Text Normalization Helpers

    internal static func normalizePhraseKey(_ text: String) -> String {
        let stripped = VNIEngine.stripDiacritics(text).lowercased()
        let parts = stripped.split(whereSeparator: { $0.isWhitespace })
        return parts.joined(separator: " ")
    }

    private static let socialNoiseLines: Set<String> = [
        "thích", "bình luận", "chia sẻ", "xem thêm", "ẩn bớt", "phản hồi",
        "like", "comment", "share", "see more", "see less", "reply",
        "tất cả cảm xúc", "viết bình luận", "phù hợp nhất", "mới nhất"
    ]

    /// Cleans pasted social media posts (e.g. Facebook posts) by removing UI chrome lines,
    /// raw URLs, and hashtags while preserving the author's natural Vietnamese/English writing style.
    private static func sanitizeCorpusText(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        var cleanedLines: [String] = []
        cleanedLines.reserveCapacity(lines.count)

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            let lower = trimmed.lowercased()
            if socialNoiseLines.contains(lower) { continue }
            if lower.contains("thích") && lower.contains("bình luận") && lower.contains("chia sẻ") { continue }

            // Strip standalone hashtags and http(s) URLs from the line
            let keptWords = trimmed
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
                .filter { word in
                    let lw = word.lowercased()
                    if lw.hasPrefix("#") { return false }
                    if lw.hasPrefix("http://") || lw.hasPrefix("https://") || lw.hasPrefix("www.") { return false }
                    return true
                }

            let joined = keptWords.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                cleanedLines.append(joined)
            }
        }
        return cleanedLines.joined(separator: "\n")
    }

    private static func splitIntoClauses(_ text: String) -> [String] {
        let sanitized = sanitizeCorpusText(text)
        let delimiters = CharacterSet(charactersIn: "\n\r.!?;")
        return sanitized
            .components(separatedBy: delimiters)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func extractWordTokens(_ clause: String) -> [String] {
        var tokens: [String] = []
        let trimChars = CharacterSet(charactersIn: ".,!?;:()[]{}\"'`~@#%^&*+=<>|\\—–…")

        for rawChunk in clause.split(whereSeparator: { $0.isWhitespace }) {
            let chunk = String(rawChunk)
            if VietnamesePhonology.isCodeOrTechnicalToken(chunk) {
                let cleaned = chunk.trimmingCharacters(in: trimChars)
                if !cleaned.isEmpty { tokens.append(cleaned) }
                continue
            }

            let cleaned = chunk.trimmingCharacters(in: trimChars)
            if cleaned.isEmpty { continue }

            // Split internal punctuation (except apostrophes inside English contractions like don't)
            var current = ""
            let chars = Array(cleaned)
            for idx in chars.indices {
                let ch = chars[idx]
                if ch.isLetter || ch.isNumber {
                    current.append(ch)
                } else if ch == "'" && idx > 0 && idx + 1 < chars.count && chars[idx - 1].isLetter && chars[idx + 1].isLetter {
                    current.append(ch)
                } else {
                    if !current.isEmpty {
                        tokens.append(current)
                        current.removeAll(keepingCapacity: true)
                    }
                }
            }
            if !current.isEmpty {
                tokens.append(current)
            }
        }
        return tokens
    }

    private static func isLearnableWord(_ baseWord: String) -> Bool {
        guard !baseWord.isEmpty, baseWord.count <= 32 else { return false }
        return baseWord.allSatisfy { $0.isLetter }
    }

    private static func detectTokenIsEnglish(
        rawToken: String,
        lowerSurface: String,
        baseWord: String,
        clauseHasVietnameseDiacritics: Bool,
        clauseMajorityEnglish: Bool
    ) -> Bool {
        if VNIEngine.containsVietnameseDiacritics(lowerSurface) {
            return false
        }
        if SeedLexicon.englishWords.contains(baseWord) && !SeedLexicon.ambiguousEnViWords.contains(baseWord) {
            return true
        }
        if !VietnamesePhonology.isValidVietnameseSyllable(baseWord) {
            return true
        }
        switch VietnamesePhonology.classifyToken(rawToken) {
        case .definiteEnglishOrCode, .likelyEnglish:
            return true
        case .ambiguous:
            return clauseMajorityEnglish && !clauseHasVietnameseDiacritics
        case .likelyVietnamese, .definiteVietnamese:
            return false
        }
    }

    private static func formatFineTuneJSONLine(
        input: String,
        output: String,
        source: String,
        userCorrected: Bool,
        useCount: Int
    ) -> String? {
        let payload: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [["text": input]]
                ],
                [
                    "role": "model",
                    "parts": [["text": output]]
                ]
            ],
            "metadata": [
                "source": source,
                "user_corrected": userCorrected,
                "use_count": useCount
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let jsonString = String(data: data, encoding: .utf8) else {
            return nil
        }
        return jsonString
    }
}
