import Testing
import Foundation
@testable import KodauCore

/// Part 3: smoother automatic changes — soft word stability ("khoá dần") and the change flash.
@Suite("SmartComposer stability")
final class SmartComposerStabilityTests {
    private let dbURL: URL
    private let store: LearningStore

    init() throws {
        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kodau-stability-\(UUID().uuidString).sqlite")
        store = try LearningStore(databaseURL: dbURL)
    }

    deinit {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbURL.path + suffix)
        }
    }

    private func makeComposer(_ config: AppConfig = AppConfig(brainStrategy: .offlineOnly)) -> SmartComposer {
        let coordinator = SmartCoordinator(store: store, config: config, geminiClient: GeminiClient())
        return SmartComposer(coordinator: coordinator)
    }

    private func key(_ ch: Character) -> ComposerKey {
        ComposerKey(keyCode: ch == " " ? 49 : 0, characters: String(ch))
    }

    @discardableResult
    private func type(_ text: String, into composer: SmartComposer) -> [ComposerAction] {
        var actions: [ComposerAction] = []
        for ch in text {
            actions += composer.handleKey(key(ch)).actions
        }
        return actions
    }

    private func space(in composer: SmartComposer) -> ComposerResult {
        composer.handleKey(key(" "))
    }

    private func flashRanges(in actions: [ComposerAction]) -> [NSRange] {
        for action in actions {
            if case .flashChangedRanges(let ranges) = action { return ranges }
        }
        return []
    }

    private func scheduledRequest(in actions: [ComposerAction]) -> RefinementRequest? {
        for action in actions {
            if case .scheduleRefinement(let request) = action { return request }
        }
        return nil
    }

    private func words(_ text: String) -> [String] {
        text.split(separator: " ").map(String.init)
    }

    /// A right-context rule that only fires once the following word is known: the plain engine answers
    /// `tôi bạn …` for two words and `tôi bán …` for three. That is exactly the flip a user sees mid-clause.
    @Test("A settled word does not flip when a later word arrives")
    func settledWordDoesNotFlip() {
        let composer = makeComposer()
        _ = type("toi ban hom nay", into: composer)
        _ = space(in: composer)
        #expect(composer.markedText == "tôi bạn hôm nay ")

        // Another process (or the dashboard) learns that `ban` before `hom` should be `bán`.
        store.recordUserCorrection(baseWord: "ban", chosenSurface: "bán", next1: "hom")

        // Sanity: the offline engine would now flip it for a fresh clause.
        let coordinator = SmartCoordinator(store: store, config: AppConfig(brainStrategy: .offlineOnly))
        #expect(coordinator.convertSync("toi ban hom nay x").convertedText == "tôi bán hôm nay x")

        // `ban` has two words after it on screen, so this composer keeps `bạn`.
        _ = type("x", into: composer)
        let afterFourth = space(in: composer)

        #expect(composer.markedText == "tôi bạn hôm nay x ")
        #expect(flashRanges(in: afterFourth.actions).isEmpty, "nothing changed, so nothing flashes")
    }

    @Test("An explicit candidate pick wins over the settled surface")
    func explicitPickOverridesStability() {
        let composer = makeComposer()
        _ = type("toi ban hom nay", into: composer)
        _ = space(in: composer)
        #expect(composer.markedText == "tôi bạn hôm nay ")

        // The popup focused `nay`; ⌥← twice reaches the ambiguous `ban` (word 1), then click `bán`.
        _ = composer.handleKey(ComposerKey(keyCode: 123, characters: nil, modifiers: [.option]))
        _ = composer.handleKey(ComposerKey(keyCode: 123, characters: nil, modifiers: [.option]))
        let picked = composer.selectCandidate("bán")
        #expect(!picked.isEmpty)
        #expect(words(composer.markedText).contains("bán"), "got: \(composer.markedText)")

        store.recordUserCorrection(baseWord: "ban", chosenSurface: "bán", next1: "hom")
        _ = type("x", into: composer)
        _ = space(in: composer)
        #expect(words(composer.markedText).contains("bán"), "the explicit pick must stick, got: \(composer.markedText)")
    }

    @Test("Backspacing into a settled word releases its stability")
    func backspaceReleasesStability() {
        let composer = makeComposer()
        _ = type("toi ban hom nay", into: composer)
        _ = space(in: composer)
        #expect(composer.markedText == "tôi bạn hôm nay ")

        // Delete back to `toi ban`, then teach the flip and retype the rest.
        for _ in 0..<9 {
            _ = composer.handleKey(ComposerKey(keyCode: 51, characters: "\u{7F}"))
        }
        #expect(VNIEngine.stripDiacritics(composer.markedText).lowercased() == "toi ban")

        store.recordUserCorrection(baseWord: "ban", chosenSurface: "bán", next1: "hom")
        _ = type(" hom nay", into: composer)
        _ = space(in: composer)
        #expect(
            words(composer.markedText).contains("bán"),
            "released stability allows the new surface, got: \(composer.markedText)"
        )
    }

    @Test("A clause re-conversion flashes the word that changed")
    func reconversionFlashesChangedWord() {
        let composer = makeComposer()
        _ = type("toi ban", into: composer)
        _ = space(in: composer)
        #expect(composer.markedText == "tôi bạn ")

        store.recordUserCorrection(baseWord: "ban", chosenSurface: "bán", next1: "hom")

        // Only one word follows `ban`, so it is not settled yet: the re-conversion rewrites it. Flash, not popup.
        _ = type("hom", into: composer)
        let changed = space(in: composer)

        #expect(composer.markedText == "tôi bán hôm ")
        let flashed = flashRanges(in: changed.actions)
        #expect(flashed.count == 1)
        guard let range = flashed.first else { return }
        #expect((composer.markedText as NSString).substring(with: range) == "bán")
        // The word the user just finished (`hom`) is never flashed: only the word that changed under them.
        let flashedWords = flashed.map { (composer.markedText as NSString).substring(with: $0) }
        #expect(!flashedWords.contains("hôm"), "got: \(flashedWords)")
    }

    @Test("Gemini may still override a settled word, and the new surface stays settled")
    func geminiOverridesSettledWord() {
        let composer = makeComposer(AppConfig(brainStrategy: .cloudFirst, geminiAPIKey: "test-key"))
        _ = type("toi ban hom nay", into: composer)
        let firstSpace = space(in: composer)
        guard let request = scheduledRequest(in: firstSpace.actions) else {
            Issue.record("expected a scheduled refinement")
            return
        }
        #expect(composer.markedText == "tôi bạn hôm nay ")

        let result = ConversionResult(
            originalText: request.raw,
            convertedText: "tôi bán hôm nay",
            confidence: 0.9,
            source: .geminiAPI,
            vietnameseRatio: 1,
            alternatives: [],
            latencyMs: 1
        )
        _ = composer.applyRefinement(result, for: request)
        #expect(composer.markedText == "tôi bán hôm nay ")

        // Gemini's rewrite becomes the new settled surface: the next local re-conversion keeps it.
        store.recordUserCorrection(baseWord: "ban", chosenSurface: "bạn", next1: "hom")
        _ = type("x", into: composer)
        _ = space(in: composer)
        #expect(composer.markedText == "tôi bán hôm nay x ")
    }

    @Test("Gemini never overrides an explicitly locked word")
    func geminiCannotOverrideLock() {
        let composer = makeComposer(AppConfig(brainStrategy: .cloudFirst, geminiAPIKey: "test-key"))

        // Inline VNI locks `bàn` explicitly.
        _ = type("toi ban", into: composer)
        _ = space(in: composer)
        _ = type("ban2", into: composer)
        #expect(composer.markedText.hasSuffix("bàn"), "got: \(composer.markedText)")

        let spaceResult = space(in: composer)
        guard let request = scheduledRequest(in: spaceResult.actions) else { return }

        let result = ConversionResult(
            originalText: request.raw,
            convertedText: "tôi bạn bán",
            confidence: 0.9,
            source: .geminiAPI,
            vietnameseRatio: 1,
            alternatives: [],
            latencyMs: 1
        )
        _ = composer.applyRefinement(result, for: request)
        #expect(composer.markedText.contains("bàn"), "an explicit lock must survive Gemini, got: \(composer.markedText)")
    }
}
