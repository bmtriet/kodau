import Testing
import Foundation
@testable import KodauCore

/// Ports of every `KodauIMController.handleKey` branch into the pure `SmartComposer`.
@Suite("SmartComposer")
final class SmartComposerTests {
    private let dbURL: URL
    private let store: LearningStore

    init() throws {
        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kodau-smart-composer-\(UUID().uuidString).sqlite")
        store = try LearningStore(databaseURL: dbURL)
    }

    deinit {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbURL.path + suffix)
        }
    }

    // MARK: - Helpers

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

    private func commits(in actions: [ComposerAction]) -> [String] {
        actions.compactMap { action in
            guard case .commit(let text) = action else { return nil }
            return text
        }
    }

    private func scheduledRequest(in actions: [ComposerAction]) -> RefinementRequest? {
        for action in actions {
            if case .scheduleRefinement(let request) = action {
                return request
            }
        }
        return nil
    }

    private func refinementResult(_ text: String, _ converted: String) -> ConversionResult {
        ConversionResult(
            originalText: text,
            convertedText: converted,
            confidence: 0.92,
            source: .geminiAPI,
            vietnameseRatio: 1.0,
            alternatives: [],
            latencyMs: 1
        )
    }

    // MARK: - Automatic Smart Mode

    @Test("Automatic Smart typing commits the fully restored sentence at punctuation")
    func automaticSmartSentence() {
        let composer = makeComposer()
        let actions = type("hom nay toi di lam.", into: composer)

        #expect(commits(in: actions) == ["hôm nay tôi đi làm."])
        #expect(composer.hasActiveBuffer == false)
        #expect(composer.markedText.isEmpty)
    }

    @Test("Return commits the pending clause and is not consumed")
    func returnCommitsAndPassesThrough() {
        let composer = makeComposer()
        type("hom nay", into: composer)

        let result = composer.handleKey(ComposerKey(keyCode: 36, characters: "\r"))

        #expect(result.handled == false)
        #expect(commits(in: result.actions) == ["hôm nay"])
        #expect(composer.hasActiveBuffer == false)
    }

    @Test("English sentences stay untouched in Smart mode")
    func englishStaysUntouched() {
        let composer = makeComposer()
        let actions = type("hello world.", into: composer)

        #expect(commits(in: actions) == ["hello world."])
        #expect(composer.hasActiveBuffer == false)
    }

    // MARK: - Manual Trigger Mode

    @Test("Manual mode keeps raw text marked until Option+Space, then commits converted punctuation")
    func manualModeConvertsOnOptionSpace() {
        let composer = makeComposer(AppConfig(brainStrategy: .offlineOnly, triggerMode: .manual))
        type("hom nay toi", into: composer)
        #expect(composer.markedText == "hom nay toi")

        let manual = composer.handleKey(ComposerKey(keyCode: 49, characters: " ", modifiers: [.option]))
        #expect(manual.handled == true)
        #expect(manual.actions.contains(.setMarked("hôm nay tôi")))
        #expect(composer.markedText == "hôm nay tôi")

        let punctuation = composer.handleKey(ComposerKey(keyCode: 47, characters: "."))
        #expect(punctuation.handled == true)
        #expect(commits(in: punctuation.actions) == ["hôm nay tôi."])
        #expect(composer.hasActiveBuffer == false)
    }

    @Test("Option+Escape commits the raw ASCII clause and teaches the store")
    func optionEscapeCommitsRaw() {
        let composer = makeComposer()
        type("hom nay", into: composer)

        let result = composer.handleKey(ComposerKey(keyCode: 53, characters: "\u{1B}", modifiers: [.option]))

        #expect(result.handled == true)
        #expect(commits(in: result.actions) == ["hom nay"])
        #expect(composer.hasActiveBuffer == false)
    }

    // MARK: - Inline VNI Override In Smart Mode

    @Test("Inline VNI `D9a6u` converts to `Đâu`")
    func inlineVNIStrokeOverride() {
        let composer = makeComposer()
        type("D9a6u", into: composer)

        let result = composer.handleKey(ComposerKey(keyCode: 36, characters: "\r"))

        #expect(commits(in: result.actions) == ["Đâu"])
    }

    @Test("Inline VNI `ban5` converts to `bạn`")
    func inlineVNIToneOverride() {
        let composer = makeComposer()
        type("ban5", into: composer)

        let result = composer.handleKey(ComposerKey(keyCode: 36, characters: "\r"))

        #expect(commits(in: result.actions) == ["bạn"])
    }

    // MARK: - Backspace

    @Test("Backspace edits the composing clause")
    func backspaceEditsClause() {
        let composer = makeComposer()
        type("hom", into: composer)

        let backspace = composer.handleKey(ComposerKey(keyCode: 51, characters: "\u{7F}"))
        #expect(backspace.handled == true)
        #expect(composer.markedText == "ho")

        type("m", into: composer)
        let result = composer.handleKey(ComposerKey(keyCode: 36, characters: "\r"))
        #expect(commits(in: result.actions) == ["hôm"])
    }

    // MARK: - Dedicated VNI Mode

    @Test("Dedicated VNI mode commits `tiếng ` when a delimiter is typed")
    func vniModeCommitsWord() {
        let composer = makeComposer(AppConfig(typingMode: .vni, brainStrategy: .offlineOnly))
        let actions = type("tie6ng1 ", into: composer)

        #expect(commits(in: actions) == ["tiếng "])
        #expect(composer.hasActiveBuffer == false)
    }

    // MARK: - English Mode

    @Test("English mode passes every key through")
    func englishModePassesEverything() {
        let composer = makeComposer(AppConfig(typingMode: .english, brainStrategy: .offlineOnly))

        for ch in "hello world" {
            let result = composer.handleKey(key(ch))
            #expect(result.handled == false)
            #expect(commits(in: result.actions).isEmpty)
        }
        #expect(composer.hasActiveBuffer == false)
    }

    // MARK: - Shortcuts

    @Test("Ctrl+Shift+Space asks the adapter to cycle the typing mode")
    func ctrlShiftSpaceCyclesMode() {
        let composer = makeComposer()

        let result = composer.handleKey(
            ComposerKey(keyCode: 49, characters: " ", modifiers: [.control, .shift])
        )

        #expect(result.handled == true)
        #expect(result.actions.contains(.cycleTypingMode))
    }

    @Test("Holding Option+Space does not re-run conversion")
    func optionSpaceRepeatIsIgnored() {
        let composer = makeComposer()
        type("hom", into: composer)

        let result = composer.handleKey(
            ComposerKey(keyCode: 49, characters: " ", modifiers: [.option], isRepeat: true)
        )

        #expect(result.handled == true)
        #expect(result.actions.isEmpty)
        #expect(composer.markedText == "hom")
    }

    @Test("Option+1 without alternatives is not consumed")
    func optionDigitWithoutAlternatives() {
        let composer = makeComposer()
        type("hom", into: composer)

        let result = composer.handleKey(
            ComposerKey(keyCode: 18, characters: "¡", modifiers: [.option])
        )

        #expect(result.handled == false)
    }

    // MARK: - Refinement

    @Test("A refinement for a stale clause version yields no actions")
    func staleRefinementIgnored() {
        let composer = makeComposer()
        type("hom", into: composer)

        let request = RefinementRequest(raw: "hom", context: "", version: 0, delayMs: 0, force: false)
        let actions = composer.applyRefinement(refinementResult("hom", "hôm"), for: request)

        #expect(actions.isEmpty)
        #expect(composer.markedText == "hom")
    }

    @Test("Space schedules a refinement using the per-sentence pause")
    func schedulesRefinementPerSentence() {
        let composer = makeComposer(AppConfig(
            brainStrategy: .cloudFirst,
            geminiAPIKey: "test-key",
            debounceMilliseconds: 450,
            geminiTiming: .perSentence,
            sentencePauseMilliseconds: 1500
        ))
        type("hom", into: composer)

        let result = composer.handleKey(ComposerKey(keyCode: 49, characters: " "))
        let request = scheduledRequest(in: result.actions)

        #expect(request != nil)
        #expect(request?.delayMs == 1500)
        #expect(request?.force == false)
    }

    @Test("Space schedules a refinement using the realtime debounce")
    func schedulesRefinementRealtime() {
        let composer = makeComposer(AppConfig(
            brainStrategy: .cloudFirst,
            geminiAPIKey: "test-key",
            debounceMilliseconds: 450,
            geminiTiming: .realtime,
            sentencePauseMilliseconds: 1500
        ))
        type("hom", into: composer)

        let result = composer.handleKey(ComposerKey(keyCode: 49, characters: " "))
        let request = scheduledRequest(in: result.actions)

        #expect(request != nil)
        #expect(request?.delayMs == 450)
        #expect(request?.force == false)
    }
}
