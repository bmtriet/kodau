import Testing
import Foundation
@testable import KodauCore

/// Corrections must be learned in their context (left word, right word, sentence start),
/// never as a global "always replace X with Y" rule.
@Suite("Context Learning Tests")
final class ContextLearningTests {
    private let dbURL: URL
    private let store: LearningStore
    private let coordinator: SmartCoordinator

    init() throws {
        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kodau-context-\(UUID().uuidString).sqlite")
        store = try LearningStore(databaseURL: dbURL)
        coordinator = SmartCoordinator(
            store: store,
            config: AppConfig(brainStrategy: .offlineOnly),
            geminiClient: GeminiClient()
        )
    }

    deinit {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbURL.path + suffix)
        }
    }

    @Test("A correction taught in one context does not replace the word in other contexts")
    func correctionStaysInContext() {
        store.recordUserCorrection(baseWord: "ban", chosenSurface: "bàn", prev1: "cái", next1: "gỗ")

        #expect(coordinator.convertSync("cai ban go nay").convertedText.hasPrefix("cái bàn"))
        #expect(coordinator.convertSync("chao ban").convertedText == "chào bạn")
        #expect(coordinator.convertSync("ban oi").convertedText == "bạn ơi")

        // The unigram is only a weak, unverified prior.
        #expect(store.unigramCandidates(for: "ban").allSatisfy { !$0.userVerified })
    }

    @Test("Right-hand context decides the word (bán hàng vs bạn ơi)")
    func rightContextDecides() {
        store.recordUserCorrection(baseWord: "ban", chosenSurface: "bán", prev1: "tôi", next1: "hàng")

        #expect(coordinator.convertSync("toi ban hang online").convertedText == "tôi bán hàng online")
        #expect(coordinator.convertSync("chao ban").convertedText == "chào bạn")
    }

    @Test("Sentence-initial corrections are learned after the <s> marker, not globally")
    func sentenceStartContext() {
        store.recordUserCorrection(baseWord: "ban", chosenSurface: "bán", prev1: nil, next1: "hang")

        let atStart = store.bigramCandidates(prevSurface: LearningStore.sentenceStartToken, baseWord: "ban")
        #expect(atStart.contains(where: { $0.surface == "bán" && $0.userVerified }))
        #expect(coordinator.convertSync("ban hang").convertedText == "bán hàng")
        #expect(coordinator.convertSync("chao ban").convertedText == "chào bạn")
    }
}
