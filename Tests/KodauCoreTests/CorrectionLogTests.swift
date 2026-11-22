import Foundation
import Testing
@testable import KodauCore

@Suite("Correction log")
final class CorrectionLogTests {

    private let tempDBURL: URL
    private let store: LearningStore

    init() throws {
        tempDBURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kodau_correction_log_\(UUID().uuidString).sqlite")
        store = try LearningStore(databaseURL: tempDBURL)
    }

    deinit {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: tempDBURL.path + suffix)
        }
    }

    private func event(
        raw: String,
        local: String,
        final: String,
        action: CorrectionAction = .candidatePick,
        wordIndex: Int = 1,
        base: String = "ban",
        wrong: String = "bán",
        right: String = "bạn",
        context: String = "",
        gemini: String? = nil
    ) -> CorrectionEvent {
        CorrectionEvent(
            appBundleID: "com.test.app",
            rawClause: raw,
            context: context,
            localOutput: local,
            geminiOutput: gemini,
            finalOutput: final,
            action: action,
            wordIndex: wordIndex,
            baseWord: base,
            wrongSurface: wrong,
            rightSurface: right,
            source: "test"
        )
    }

    @Test("The schema includes correction_events and the log starts empty")
    func schemaAndEmptyLog() {
        #expect(store.recentCorrectionEvents(limit: 10).isEmpty)
        #expect(store.topCorrectionMistakes(limit: 10).isEmpty)
        #expect(store.exportCorrectionCorpusJSONL().isEmpty)
    }

    @Test("Recording an event stores every field, including nullable Gemini output")
    func roundTrip() throws {
        store.recordCorrectionEvent(event(
            raw: "toi ban hang",
            local: "tôi bán hàng",
            final: "tôi bạn hàng",
            gemini: "tôi bán hàng"
        ))

        let events = store.recentCorrectionEvents(limit: 10)
        #expect(events.count == 1)
        let stored = try #require(events.first)
        #expect(stored.appBundleID == "com.test.app")
        #expect(stored.rawClause == "toi ban hang")
        #expect(stored.localOutput == "tôi bán hàng")
        #expect(stored.geminiOutput == "tôi bán hàng")
        #expect(stored.finalOutput == "tôi bạn hàng")
        #expect(stored.action == .candidatePick)
        #expect(stored.wordIndex == 1)
        #expect(stored.baseWord == "ban")
        #expect(stored.wrongSurface == "bán")
        #expect(stored.rightSurface == "bạn")
        #expect(stored.source == "test")
        #expect(stored.id != nil)
    }

    @Test("An event without Gemini output stores NULL, not an empty string")
    func geminiOutputIsOptional() throws {
        store.recordCorrectionEvent(event(raw: "toi ban hang", local: "tôi bán hàng", final: "tôi bạn hàng"))
        let stored = try #require(store.recentCorrectionEvents(limit: 1).first)
        #expect(stored.geminiOutput == nil)
    }

    @Test("Empty clauses are ignored so the log never fills with junk rows")
    func emptyClausesAreIgnored() {
        store.recordCorrectionEvent(event(raw: "   ", local: "", final: "tôi bạn hàng"))
        store.recordCorrectionEvent(event(raw: "toi ban hang", local: "", final: "  "))
        #expect(store.recentCorrectionEvents(limit: 10).isEmpty)
    }

    @Test("topCorrectionMistakes groups by base + wrong + right, counts hits, and keeps the newest example")
    func groupsMistakes() throws {
        store.recordCorrectionEvent(event(
            raw: "toi ban hang", local: "tôi bán hàng", final: "tôi bạn hàng", context: "moi ngay"
        ))
        store.recordCorrectionEvent(event(
            raw: "ban co ranh khong", local: "bán có rảnh không", final: "bạn có rảnh không", context: "chao"
        ))
        store.recordCorrectionEvent(event(
            raw: "toi ban roi", local: "tôi bán rồi", final: "tôi bàn rồi", right: "bàn"
        ))

        let mistakes = store.topCorrectionMistakes(limit: 20)
        #expect(mistakes.count == 2)

        // `ban -> bán/bạn` happens twice, so it ranks first.
        let top = try #require(mistakes.first)
        #expect(top.baseWord == "ban")
        #expect(top.wrongSurface == "bán")
        #expect(top.rightSurface == "bạn")
        #expect(top.count == 2)
        #expect(top.exampleRawClause == "ban co ranh khong", "expected the newest example, got: \(top.exampleRawClause)")
        #expect(top.exampleContext == "chao")
        #expect(top.exampleSentence == "chao ban co ranh khong")

        let second = try #require(mistakes.last)
        #expect(second.rightSurface == "bàn")
        #expect(second.count == 1)
    }

    @Test("topCorrectionMistakes honours the limit")
    func mistakesLimit() {
        for index in 0..<8 {
            store.recordCorrectionEvent(event(
                raw: "toi ban hang",
                local: "tôi bán hàng",
                final: "tôi bạn hàng",
                right: "bạn\(index)"
            ))
        }
        #expect(store.topCorrectionMistakes(limit: 3).count == 3)
    }

    @Test("recentCorrectionEvents returns newest first and honours the limit")
    func recentOrdering() {
        for index in 0..<5 {
            store.recordCorrectionEvent(event(
                raw: "cau so \(index)",
                local: "câu số \(index)",
                final: "câu số \(index) đúng",
                wordIndex: index
            ))
        }
        let recent = store.recentCorrectionEvents(limit: 3)
        #expect(recent.count == 3)
        #expect(recent.map(\.wordIndex) == [4, 3, 2])
    }

    @Test("clearCorrectionEvents empties the log but keeps the learned dictionary")
    func clearKeepsDictionary() {
        store.recordUserCorrection(baseWord: "ban", chosenSurface: "bạn", prev1: "toi")
        store.recordCorrectionEvent(event(raw: "toi ban hang", local: "tôi bán hàng", final: "tôi bạn hàng"))

        store.clearCorrectionEvents()

        #expect(store.recentCorrectionEvents(limit: 10).isEmpty)
        #expect(!store.bigramCandidates(prevSurface: "toi", baseWord: "ban").isEmpty)
    }

    @Test("Export emits Part-2 corpus lines and skips clauses whose word count changed")
    func exportCorpus() throws {
        store.recordCorrectionEvent(event(
            raw: "toi ban hang", local: "tôi bán hàng", final: "tôi bạn hàng", context: "moi ngay"
        ))
        // Same word count: exported.
        store.recordCorrectionEvent(event(
            raw: "toi ban hang online", local: "tôi bán hàng online", final: "tôi bạn hàng online"
        ))
        // Reworded / different word count: skipped.
        store.recordCorrectionEvent(event(
            raw: "toi ban hang", local: "tôi bán hàng", final: "tôi bán mặt hàng này"
        ))
        // Duplicate raw clause: only the first is exported.
        store.recordCorrectionEvent(event(
            raw: "toi ban hang", local: "tôi bán hàng", final: "tôi bạn hàng"
        ))

        let exported = store.exportCorrectionCorpusJSONL()
        let lines = exported.split(separator: "\n").map(String.init)
        #expect(lines.count == 2, "got: \(exported)")

        struct Line: Decodable {
            let raw: String
            let expected: String
            let context: String
        }
        let decoded = try lines.map { try JSONDecoder().decode(Line.self, from: Data($0.utf8)) }
        #expect(decoded[0].raw == "toi ban hang")
        #expect(decoded[0].expected == "tôi bạn hàng")
        #expect(decoded[0].context == "moi ngay")
        #expect(decoded[1].raw == "toi ban hang online")
    }

    @Test("The exported line is a valid BenchmarkLine")
    func exportIsBenchmarkCompatible() throws {
        store.recordCorrectionEvent(event(raw: "toi ban hang", local: "tôi bán hàng", final: "tôi bạn hàng"))
        let exported = store.exportCorrectionCorpusJSONL()
        let line = try #require(exported.split(separator: "\n").first.map(String.init))
        let parsed = try JSONDecoder().decode(BenchmarkLine.self, from: Data(line.utf8))
        #expect(parsed.raw == "toi ban hang")
        #expect(parsed.expected == "tôi bạn hàng")
        #expect(parsed.context == "")
    }
}
