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

    private func candidate(in actions: [ComposerAction]) -> WordAlternative? {
        presentation(in: actions)?.alternative
    }

    private func presentation(in actions: [ComposerAction]) -> CandidatePresentation? {
        for action in actions {
            if case .showCandidates(let presentation) = action {
                return presentation
            }
        }
        return nil
    }

    private func refinementResult(
        _ text: String,
        _ converted: String,
        alternatives: [WordAlternative] = []
    ) -> ConversionResult {
        ConversionResult(
            originalText: text,
            convertedText: converted,
            confidence: 0.92,
            source: .geminiAPI,
            vietnameseRatio: 1.0,
            alternatives: alternatives,
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

    // MARK: - Candidate Popup

    @Test("selectCandidate applies the chosen surface and teaches the store")
    func selectCandidateAppliesAndLearns() {
        let composer = makeComposer()
        let typed = type("ban ", into: composer)
        guard let alternative = candidate(in: typed) else {
            Issue.record("expected a .showCandidates action for the ambiguous word `ban`")
            return
        }
        guard let chosen = alternative.candidates.first(where: {
            $0.lowercased() != alternative.selected.lowercased()
        }) else {
            Issue.record("expected more than one candidate")
            return
        }

        let applied = composer.selectCandidate(chosen)

        #expect(applied.contains(.hideCandidates))
        #expect(composer.markedText.lowercased().contains(chosen.lowercased()))
        let learned = store.bigramCandidates(
            prevSurface: LearningStore.sentenceStartToken,
            baseWord: "ban"
        )
        #expect(learned.contains { $0.surface.lowercased() == chosen.lowercased() && $0.userVerified })
    }

    @Test("revertToRaw commits the raw ASCII clause")
    func revertToRawCommitsRaw() {
        let composer = makeComposer()
        type("hom nay", into: composer)

        let actions = composer.revertToRaw()

        #expect(commits(in: actions) == ["hom nay"])
        #expect(composer.hasActiveBuffer == false)
    }

    @Test("Committing the clause hides the candidate popup")
    func commitHidesCandidates() {
        let composer = makeComposer()
        let typed = type("ban ", into: composer)
        guard candidate(in: typed) != nil else {
            Issue.record("expected a .showCandidates action for the ambiguous word `ban`")
            return
        }

        let result = composer.handleKey(ComposerKey(keyCode: 36, characters: "\r"))

        #expect(result.actions.contains(.hideCandidates))
    }

    @Test("Typing after showing candidates hides the popup")
    func continuedTypingHidesCandidates() {
        let composer = makeComposer()
        let typed = type("ban ", into: composer)
        guard candidate(in: typed) != nil else {
            Issue.record("expected a .showCandidates action for the ambiguous word `ban`")
            return
        }

        let result = composer.handleKey(key("x"))

        #expect(result.actions.contains(.hideCandidates))
    }

    // MARK: - Stale VNI Refinement

    @Test("VNI refinement scheduled by Option+Space is dropped after more VNI typing")
    func staleVNIRefinementIgnored() {
        let composer = makeComposer(AppConfig(
            typingMode: .vni,
            brainStrategy: .cloudFirst,
            geminiAPIKey: "test-key"
        ))
        type("tieng", into: composer)

        let manual = composer.handleKey(
            ComposerKey(keyCode: 49, characters: " ", modifiers: [.option])
        )
        guard let request = scheduledRequest(in: manual.actions) else {
            Issue.record("expected Option+Space to schedule a refinement")
            return
        }

        type("x", into: composer)

        let actions = composer.applyRefinement(refinementResult("tieng", "tiếng"), for: request)

        #expect(actions.isEmpty)
    }

    // MARK: - Focused Candidate (Part A)

    @Test("Space only auto-shows the popup when the just-completed word is ambiguous")
    func popupOnlyForJustCompletedWord() {
        let composer = makeComposer()
        type("ban tieng", into: composer)

        let space = composer.handleKey(key(" "))

        #expect(space.handled == true)
        #expect(presentation(in: space.actions) == nil)
    }

    @Test("Space auto-shows the popup for the last word when it is ambiguous")
    func popupForAmbiguousLastWord() {
        let composer = makeComposer()
        type("ban", into: composer)

        let space = composer.handleKey(key(" "))

        let shown = presentation(in: space.actions)
        #expect(shown != nil)
        #expect(shown?.alternative.wordIndex == 0)
    }

    @Test("Option+Left/Right cycle the focused ambiguous word and aren't consumed without a buffer")
    func optionArrowsCycleFocus() {
        let empty = makeComposer()
        for keyCode: UInt16 in [123, 124] {
            let result = empty.handleKey(ComposerKey(keyCode: keyCode, modifiers: [.option]))
            #expect(result.handled == false)
            #expect(result.actions.isEmpty)
        }

        let composer = makeComposer()
        type("sac huyen hoi nga nang", into: composer)
        let spaced = composer.handleKey(key(" "))
        #expect(presentation(in: spaced.actions)?.alternative.wordIndex == 4)

        let left = composer.handleKey(ComposerKey(keyCode: 123, modifiers: [.option]))
        #expect(left.handled == true)
        #expect(presentation(in: left.actions)?.alternative.wordIndex == 3)
        #expect(presentation(in: left.actions)?.showsImmediately == true)

        let leftAgain = composer.handleKey(ComposerKey(keyCode: 123, modifiers: [.option]))
        #expect(presentation(in: leftAgain.actions)?.alternative.wordIndex == 2)

        let right = composer.handleKey(ComposerKey(keyCode: 124, modifiers: [.option]))
        #expect(presentation(in: right.actions)?.alternative.wordIndex == 3)

        // ⌥2 now applies to word 3 ("ngã"), whose second candidate is "nga".
        let applied = composer.handleKey(ComposerKey(keyCode: 19, characters: "2", modifiers: [.option]))
        #expect(applied.handled == true)
        let tokens = composer.markedText.split(separator: " ").map(String.init)
        #expect(tokens.count == 5)
        #expect(tokens[3] == "nga")
    }

    @Test("Focused range highlights the right UTF-16 word including diacritics")
    func focusedRangeMatchesWord() {
        let composer = makeComposer()
        type("ban", into: composer)
        let space = composer.handleKey(key(" "))
        guard let shown = presentation(in: space.actions) else {
            Issue.record("expected a candidate presentation")
            return
        }

        let marked = composer.markedText
        let firstWord = String(marked.split(separator: " ").first ?? "")
        let highlighted = (marked as NSString).substring(with: shown.focusedRange)

        #expect(shown.focusedRange.location == 0)
        #expect(highlighted == firstWord)
        #expect(shown.focusedRange.length == (firstWord as NSString).length)
        #expect(firstWord.unicodeScalars.contains { $0.value > 0x7F })
    }

    // MARK: - Gemini Changes (Part C)

    @Test("A refinement that changes a word reports the change and focuses that word")
    func refinementReportsGeminiChanges() {
        let composer = makeComposer(AppConfig(brainStrategy: .cloudFirst, geminiAPIKey: "test-key"))
        type("hom nay", into: composer)
        let space = composer.handleKey(key(" "))
        guard let request = scheduledRequest(in: space.actions) else {
            Issue.record("expected a scheduled refinement")
            return
        }
        #expect(composer.markedText == "hôm nay ")

        let changed = composer.applyRefinement(refinementResult(request.raw, "hôm này"), for: request)
        guard let shown = presentation(in: changed) else {
            Issue.record("expected a candidate presentation for the Gemini change")
            return
        }

        #expect(shown.geminiChanges == [GeminiChange(wordIndex: 1, from: "nay", to: "này")])
        #expect(shown.alternative.wordIndex == 1)
        #expect(shown.showsImmediately == true)
        #expect(composer.markedText == "hôm này ")
    }

    @Test("Option+Escape after a Gemini change reverts only that word, keeps composing, and locks it")
    func optionEscapeRevertsOnlyGeminiChanges() {
        let composer = makeComposer(AppConfig(brainStrategy: .cloudFirst, geminiAPIKey: "test-key"))
        type("hom nay", into: composer)
        let space = composer.handleKey(key(" "))
        guard let request = scheduledRequest(in: space.actions) else {
            Issue.record("expected a scheduled refinement")
            return
        }
        _ = composer.applyRefinement(refinementResult(request.raw, "hôm này"), for: request)
        #expect(composer.markedText == "hôm này ")

        let revert = composer.handleKey(ComposerKey(keyCode: 53, characters: "\u{1B}", modifiers: [.option]))

        #expect(revert.handled == true)
        #expect(commits(in: revert.actions).isEmpty)
        #expect(composer.hasActiveBuffer == true)
        #expect(composer.markedText == "hôm nay ")

        let learned = store.bigramCandidates(prevSurface: "hôm", baseWord: "nay")
        #expect(learned.contains { $0.surface.lowercased() == "nay" && $0.userVerified })

        // A later refinement must not undo the user's revert: the word is locked.
        let more = type("x ", into: composer)
        guard let nextRequest = scheduledRequest(in: more) else {
            Issue.record("expected a subsequent scheduled refinement")
            return
        }
        _ = composer.applyRefinement(
            refinementResult(nextRequest.raw, "hôm này x"),
            for: nextRequest
        )
        #expect(composer.markedText == "hôm nay x ")
    }

    @Test("Word locks after a hyphenated word stay on the right word")
    func locksAfterHyphenatedWord() {
        let composer = makeComposer()
        _ = type("check e-mail ban5 nhe", into: composer)
        #expect(composer.markedText.contains("e-mail bạn"), "got: \(composer.markedText)")
    }

}
