import Testing
import Foundation
import SQLite3
@testable import KodauCore

/// The model must never change the user's words beyond what the mode allows, whatever it returns.
@Suite("Gemini Output Guard Tests")
struct GeminiOutputGuardTests {

    private func sanitize(_ original: String, _ restored: String, _ mode: GeminiRestoreMode = .diacriticsOnly) throws -> String {
        try GeminiClient.sanitizeAndValidate(original: original, restored: restored, mode: mode)
    }

    @Test("Diacritics-only: adding diacritics is accepted, keeping user's spacing and punctuation")
    func diacriticsAccepted() throws {
        #expect(try sanitize("hom nay  toi di lam, ok", "hôm nay tôi đi làm. ok") == "hôm nay  tôi đi làm, ok")
    }

    @Test("Diacritics-only: spelling fixes, expansions and translations are reverted to the user's word")
    func rewritesReverted() throws {
        #expect(try sanitize("toi ko di dnag hoc", "tôi không đi đang học") == "tôi ko đi dnag học")
        #expect(try sanitize("hom nay toi fix bug", "hôm nay tôi sửa bug") == "hôm nay tôi fix bug")
    }

    @Test("Added, dropped or merged words reject the whole response (caller falls back to the local engine)")
    func wordCountChangeRejected() {
        #expect(throws: GeminiError.self) { try sanitize("toi di hoc", "tôi đi học rồi") }
        #expect(throws: GeminiError.self) { try sanitize("toi di hoc ve", "tôi đi học") }
    }

    @Test("Casing pattern of the user's word is preserved")
    func casingPreserved() throws {
        #expect(try sanitize("Toi DI hoc", "tôi đi học") == "Tôi ĐI học")
    }

    @Test("Typo mode fixes clear misspellings within a small edit distance")
    func typoModeFixes() throws {
        #expect(try sanitize("toi dnag hoc teh code", "tôi đang học the code", .fixTypos) == "tôi đang học the code")
        #expect(try sanitize("i recieve it", "i receive it", .fixTypos) == "i receive it")
    }

    @Test("Typo mode still never expands abbreviations, rewrites words, or touches code")
    func typoModeLimits() throws {
        #expect(try sanitize("minh ko dc di dau het", "mình không được đi đâu hết", .fixTypos) == "mình ko dc đi đâu hết")
        #expect(!GeminiClient.isAllowedWordChange(from: "hello", to: "xin", mode: .fixTypos))
        #expect(!GeminiClient.isAllowedWordChange(from: "v2.1", to: "v2.2", mode: .fixTypos))
        #expect(!GeminiClient.isAllowedWordChange(from: "dnag", to: "đang", mode: .diacriticsOnly))
        #expect(GeminiClient.isAllowedWordChange(from: "khogn", to: "không", mode: .fixTypos))
    }

    @Test("Damerau-Levenshtein counts an adjacent swap as one edit")
    func distance() {
        #expect(GeminiClient.damerauLevenshtein(Array("teh"), Array("the")) == 1)
        #expect(GeminiClient.damerauLevenshtein(Array("dnag"), Array("dang")) == 1)
        #expect(GeminiClient.damerauLevenshtein(Array("abc"), Array("xyz")) == 3)
    }

    @Test("Corrections that change the word itself are never learned")
    func mismatchedCorrectionNotLearned() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        store.recordUserCorrection(
            baseWord: "ko", chosenSurface: "không", prev1: "toi",
            fullRawClause: "toi ko di", fullCorrectedClause: "tôi không đi"
        )
        #expect(store.unigramCandidates(for: "ko").isEmpty)
        #expect(store.bigramCandidates(prevSurface: "toi", baseWord: "ko").isEmpty)
        #expect(store.lookupPhrase(rawNoDiacritics: "toi ko di") == nil)
    }

    @Test("Polluted rows already in the database are never replayed")
    func pollutedRowsIgnored() throws {
        let (store, cleanup, dbPath) = try makeStoreWithPath()
        defer { cleanup() }
        _ = store.unigramCandidates(for: "a") // ensure schema exists

        var db: OpaquePointer?
        #expect(sqlite3_open(dbPath, &db) == SQLITE_OK)
        let now = Date().timeIntervalSince1970
        let sql = """
            INSERT INTO unigrams (base_word, surface, count, user_verified, is_english, updated_at) VALUES ('ko', 'không', 50, 1, 0, \(now));
            INSERT INTO bigrams (prev_surface, base_word, surface, count, user_verified, updated_at) VALUES ('<s>', 'ko', 'không', 50, 1, \(now));
            INSERT INTO phrases (raw_norm, restored, source, user_corrected, use_count, updated_at) VALUES ('ko di dau', 'không đi đâu', 'gemini', 1, 9, \(now));
            """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let coordinator = SmartCoordinator(store: store, config: AppConfig(brainStrategy: .offlineOnly), geminiClient: GeminiClient())
        let output = coordinator.convertSync("ko di dau").convertedText
        #expect(!output.contains("không"), "Expected the user's 'ko' to survive, got: \(output)")
        #expect(output.hasPrefix("ko"))
    }

    private func makeStore() throws -> (LearningStore, () -> Void) {
        let (store, cleanup, _) = try makeStoreWithPath()
        return (store, cleanup)
    }

    private func makeStoreWithPath() throws -> (LearningStore, () -> Void, String) {
        let dbURL = FileManager.default.temporaryDirectory.appendingPathComponent("kodau-guard-\(UUID().uuidString).sqlite")
        let store = try LearningStore(databaseURL: dbURL)
        let cleanup = {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbURL.path + suffix) }
        }
        return (store, cleanup, dbURL.path)
    }
}
