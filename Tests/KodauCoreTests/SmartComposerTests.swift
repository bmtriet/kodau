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

    private func flashRanges(in actions: [ComposerAction]) -> [NSRange] {
        for action in actions {
            if case .flashChangedRanges(let ranges) = action { return ranges }
        }
        return []
    }

    private func correctionEvents(in actions: [ComposerAction]) -> [CorrectionEvent] {
        actions.compactMap { action in
            guard case .recordCorrection(let event) = action else { return nil }
            return event
        }
    }

    /// The last `.showCandidates` in a batch of accumulated actions.
    private func lastPresentation(in actions: [ComposerAction]) -> CandidatePresentation? {
        for action in actions.reversed() {
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

    @Test("A Gemini change to an unambiguous word flashes it and does not nag with the popup")
    func refinementFlashesUnambiguousChange() {
        let composer = makeComposer(AppConfig(brainStrategy: .cloudFirst, geminiAPIKey: "test-key"))
        type("hom nay", into: composer)
        let space = composer.handleKey(key(" "))
        guard let request = scheduledRequest(in: space.actions) else {
            Issue.record("expected a scheduled refinement")
            return
        }
        #expect(composer.markedText == "hôm nay ")

        let changed = composer.applyRefinement(refinementResult(request.raw, "hôm này"), for: request)

        // `này` has a single plausible surface, so this is a flash, not a question.
        #expect(presentation(in: changed) == nil)
        let flash = flashRanges(in: changed)
        #expect(flash.count == 1)
        let marked = composer.markedText as NSString
        #expect(marked.substring(with: flash[0]) == "này")
        #expect(composer.markedText == "hôm này ")

        // The change is still rejectable with ⌥Esc, which proves `pendingGeminiChanges` was recorded.
        let revert = composer.handleKey(ComposerKey(keyCode: 53, characters: "\u{1B}", modifiers: [.option]))
        #expect(composer.markedText == "hôm nay ")
        #expect(correctionEvents(in: revert.actions).count == 1)
    }

    @Test("A Gemini change to a genuinely ambiguous word flashes and still shows the popup")
    func refinementPopsForAmbiguousChange() {
        let composer = makeComposer(AppConfig(brainStrategy: .cloudFirst, geminiAPIKey: "test-key"))
        type("toi ban hang", into: composer)
        let space = composer.handleKey(key(" "))
        guard let request = scheduledRequest(in: space.actions) else {
            Issue.record("expected a scheduled refinement")
            return
        }

        // The local answer is `tôi bạn hàng`; Gemini rewrites `bạn` -> `bàn`, and that word is ambiguous.
        #expect(composer.markedText == "tôi bạn hàng ")
        let result = ConversionResult(
            originalText: request.raw,
            convertedText: "tôi bàn hàng",
            confidence: 0.9,
            source: .geminiAPI,
            vietnameseRatio: 1,
            alternatives: [
                WordAlternative(
                    wordIndex: 1,
                    baseWord: "ban",
                    selected: "bàn",
                    candidates: ["bàn", "bạn", "bán"]
                )
            ],
            latencyMs: 1
        )
        let changed = composer.applyRefinement(result, for: request)

        let shown = presentation(in: changed)
        #expect(shown != nil)
        #expect(shown?.geminiChanges == [GeminiChange(wordIndex: 1, from: "bạn", to: "bàn")])
        #expect(shown?.showsImmediately == true)
        let flashed = flashRanges(in: changed)
        #expect(flashed.count == 1)
        #expect((composer.markedText as NSString).substring(with: flashed[0]) == "bàn")
        #expect(composer.markedText == "tôi bàn hàng ")
    }

    @Test("A refinement requested before more letters were typed is discarded")
    func staleRefinementAfterTypingIsDiscarded() {
        let composer = makeComposer(AppConfig(brainStrategy: .cloudFirst, geminiAPIKey: "test-key"))
        type("hom", into: composer)
        let first = composer.handleKey(key(" "))
        guard let request = scheduledRequest(in: first.actions) else {
            Issue.record("expected a scheduled refinement")
            return
        }

        // The user keeps typing into the next word before Gemini answered.
        _ = type("nay", into: composer)
        let before = composer.markedText

        let actions = composer.applyRefinement(refinementResult(request.raw, "hôm này"), for: request)

        #expect(actions.isEmpty)
        #expect(composer.markedText == before)
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

    // MARK: - "Xem thêm" (⌥6) Expanded Candidates

    private static let optionSix = ComposerKey(keyCode: 22, characters: "§", modifiers: [.option])
    private static let optionE = ComposerKey(keyCode: 14, characters: "´", modifiers: [.option])

    /// Moves the popup focus to `wordIndex` with `⌥←`, returning `false` when it cannot be reached.
    @discardableResult
    private func focusWord(_ wordIndex: Int, in composer: SmartComposer) -> Bool {
        for _ in 0..<12 {
            let step = composer.handleKey(ComposerKey(keyCode: 123, modifiers: [.option]))
            if presentation(in: step.actions)?.alternative.wordIndex == wordIndex {
                return true
            }
        }
        return false
    }

    @Test("Option+6 is not consumed without a focused word")
    func optionSixWithoutFocus() {
        let empty = SmartComposerTests.makeEmptyComposer()
        #expect(empty.handleKey(Self.optionSix).handled == false)

        // A clause with no ambiguity has no focused word either.
        let composer = makeComposer()
        type("hom", into: composer)
        #expect(composer.handleKey(Self.optionSix).handled == false)
    }

    private static func makeEmptyComposer() -> SmartComposer {
        let store = try! LearningStore(
            databaseURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("kodau-empty-\(UUID().uuidString).sqlite")
        )
        let coordinator = SmartCoordinator(store: store, config: AppConfig(brainStrategy: .offlineOnly), geminiClient: GeminiClient())
        return SmartComposer(coordinator: coordinator)
    }

    @Test("Option+6 shows page 1 of the focused word, then page 2 on a second press")
    func optionSixPages() {
        let composer = makeComposer()
        type("ban", into: composer)
        _ = composer.handleKey(key(" "))
        guard let normal = presentation(in: composer.handleKey(ComposerKey(keyCode: 123, modifiers: [.option])).actions) else {
            Issue.record("expected the focused popup")
            return
        }
        #expect(normal.isExpanded == false)

        let first = composer.handleKey(Self.optionSix)
        #expect(first.handled == true)
        guard let page1 = presentation(in: first.actions) else {
            Issue.record("expected an expanded presentation")
            return
        }
        #expect(page1.isExpanded == true)
        #expect(page1.page == 1)
        #expect(page1.pageCount > 1)
        #expect(page1.alternative.candidates.count <= SmartComposer.expandedPageSize)
        // The quick candidates still lead page 1.
        #expect(page1.alternative.candidates.first == normal.alternative.candidates.first)

        let second = composer.handleKey(Self.optionSix)
        guard let page2 = presentation(in: second.actions) else {
            Issue.record("expected page 2")
            return
        }
        #expect(page2.page == 2)
        #expect(page2.pageCount == page1.pageCount)
        #expect(page2.alternative.candidates != page1.alternative.candidates)
    }

    @Test("Option+6 wraps back to page 1 from the last page")
    func optionSixWraps() {
        let composer = makeComposer()
        type("ban", into: composer)
        _ = composer.handleKey(key(" "))

        guard let page1 = presentation(in: composer.handleKey(Self.optionSix).actions) else {
            Issue.record("expected page 1")
            return
        }
        var last = page1
        for _ in 0..<(page1.pageCount - 1) {
            guard let next = presentation(in: composer.handleKey(Self.optionSix).actions) else {
                Issue.record("expected the last page")
                return
            }
            last = next
        }
        #expect(last.page == page1.pageCount)

        let wrapped = presentation(in: composer.handleKey(Self.optionSix).actions)
        #expect(wrapped?.page == 1)
    }

    @Test("Option+1..5 on page 2 applies the right word and locks it")
    func optionDigitsPickFromSecondPage() {
        let composer = makeComposer()
        type("ban", into: composer)
        _ = composer.handleKey(key(" "))
        guard let page1 = presentation(in: composer.handleKey(Self.optionSix).actions),
              let page2 = presentation(in: composer.handleKey(Self.optionSix).actions) else {
            Issue.record("expected two pages")
            return
        }
        guard page2.alternative.candidates.count >= 2 else {
            Issue.record("expected at least two candidates on page 2")
            return
        }
        let target = page2.alternative.candidates[1]

        let applied = composer.handleKey(ComposerKey(keyCode: 19, characters: "2", modifiers: [.option]))
        #expect(applied.handled == true)
        #expect(applied.actions.contains(.hideCandidates))
        #expect(composer.markedText.hasPrefix(target))

        // The pick is locked: a later refinement must not undo it.
        let learned = store.unigramCandidates(for: "ban")
        #expect(learned.contains { $0.surface.lowercased() == target.lowercased() })
        #expect(page1.pageCount == page2.pageCount)
    }

    @Test("Typing resets the expanded paging")
    func typingResetsPaging() {
        let composer = makeComposer()
        type("ban", into: composer)
        _ = composer.handleKey(key(" "))
        guard presentation(in: composer.handleKey(Self.optionSix).actions) != nil else {
            Issue.record("expected the expanded popup")
            return
        }
        _ = composer.handleKey(Self.optionSix)

        let next = composer.handleKey(key("x"))
        #expect(next.actions.contains(.hideCandidates))

        // Re-focusing the word starts again at page 1.
        guard focusWord(0, in: composer) else {
            Issue.record("expected focus on word 0")
            return
        }
        let shown = presentation(in: composer.handleKey(Self.optionSix).actions)
        #expect(shown?.page == 1)
    }

    // MARK: - "Gõ từ khác" (⌥E) Inline Retype

    @Test("Option+E is not consumed without a focused word")
    func optionEWithoutFocus() {
        let empty = makeComposer()
        #expect(empty.handleKey(Self.optionE).handled == false)

        let composer = makeComposer()
        type("hom", into: composer)
        #expect(composer.handleKey(Self.optionE).handled == false)
    }

    @Test("Option+E retypes only the middle word and keeps later words untouched")
    func optionERetypesMiddleWord() {
        let composer = makeComposer(AppConfig(brainStrategy: .cloudFirst, geminiAPIKey: "test-key"))
        type("toi di ban nay", into: composer)
        _ = composer.handleKey(key(" "))
        guard focusWord(2, in: composer) else {
            Issue.record("expected focus on word 2, got: \(composer.markedText)")
            return
        }
        #expect(composer.markedText == "tôi đi bạn này ")

        let started = composer.handleKey(Self.optionE)
        #expect(started.handled == true)
        #expect(presentation(in: started.actions)?.editHint != nil)

        // Type `ba6n5` then Return.
        var typedActions: [ComposerAction] = []
        for ch in "ba6n5" {
            typedActions += composer.handleKey(key(ch)).actions
        }
        #expect(lastPresentation(in: typedActions)?.editHint?.contains("bận") == true)
        #expect(composer.markedText == "tôi đi bận này ")

        let confirmed = composer.handleKey(ComposerKey(keyCode: 36, characters: "\r"))
        #expect(confirmed.handled == true)
        #expect(confirmed.actions.contains(.hideCandidates))
        #expect(composer.hasActiveBuffer == true)
        #expect(composer.markedText == "tôi đi bận này ")

        // A later refinement that changes that index must not override the lock, and later words stay as typed.
        let more = type("x ", into: composer)
        guard let request = scheduledRequest(in: more) else {
            Issue.record("expected a scheduled refinement")
            return
        }
        _ = composer.applyRefinement(refinementResult(request.raw, "tôi đi bán này x"), for: request)
        #expect(composer.markedText == "tôi đi bận này x ")

        // Committing the clause keeps the aligned text.
        let committed = composer.handleKey(ComposerKey(keyCode: 36, characters: "\r"))
        #expect(commits(in: committed.actions) == ["tôi đi bận này x "])
    }

    @Test("Option+E then Escape restores the clause exactly")
    func optionECancelRestores() {
        let composer = makeComposer()
        type("toi di ban nay", into: composer)
        _ = composer.handleKey(key(" "))
        guard focusWord(2, in: composer) else {
            Issue.record("expected focus on word 2")
            return
        }
        let before = composer.markedText

        let started = composer.handleKey(Self.optionE)
        #expect(started.handled == true)
        for ch in "ba6n5" {
            _ = composer.handleKey(key(ch))
        }

        let cancelled = composer.handleKey(ComposerKey(keyCode: 53, characters: "\u{1B}"))
        #expect(cancelled.handled == true)
        #expect(composer.markedText == before)
        #expect(composer.hasActiveBuffer == true)

        // The sub-state is gone: a normal letter now types into the clause again.
        let after = composer.handleKey(key("x"))
        #expect(after.handled == true)
        #expect(composer.markedText.count == before.count + 1)
    }

    @Test("Option+E plus Option+Escape also cancels")
    func optionECancelWithOptionEscape() {
        let composer = makeComposer()
        type("ban", into: composer)
        _ = composer.handleKey(key(" "))
        let before = composer.markedText

        _ = composer.handleKey(Self.optionE)
        let cancelled = composer.handleKey(
            ComposerKey(keyCode: 53, characters: "\u{1B}", modifiers: [.option])
        )
        #expect(cancelled.handled == true)
        #expect(composer.markedText == before)
    }

    @Test("Option+E then Backspace on an empty buffer cancels")
    func optionEBackspaceOnEmptyCancels() {
        let composer = makeComposer()
        type("ban", into: composer)
        _ = composer.handleKey(key(" "))
        let before = composer.markedText

        _ = composer.handleKey(Self.optionE)
        let cancelled = composer.handleKey(ComposerKey(keyCode: 51, characters: "\u{7F}"))
        #expect(cancelled.handled == true)
        #expect(composer.markedText == before)
    }

    @Test("Option+E rejects a confirm that would split into several words")
    func optionERejectsMultiWord() {
        let composer = makeComposer()
        type("ban", into: composer)
        _ = composer.handleKey(key(" "))
        let before = composer.markedText

        _ = composer.handleKey(Self.optionE)
        // A hyphen is folded into one atomic token; a space is not accepted as a word character here, so the
        // guard is reached through a buffer that `TextSegmenter` splits (letters + punctuation).
        for ch in "ban-xyz" {
            _ = composer.handleKey(key(ch))
        }
        let rejected = composer.handleKey(ComposerKey(keyCode: 36, characters: "\r"))
        // Still editing: the hint is showing and the clause is unchanged so far.
        #expect(rejected.handled == true)
        #expect(presentation(in: rejected.actions)?.editHint != nil)
        #expect(composer.markedText.hasPrefix("ban-xyz"))
        #expect(before.hasPrefix("bạn"))

        let cancelled = composer.handleKey(ComposerKey(keyCode: 53, characters: "\u{1B}"))
        #expect(cancelled.handled == true)
        #expect(composer.markedText == before)
    }

    @Test("The popup's edit chip mirrors Option+E")
    func editChipMirrorsShortcut() {
        let composer = makeComposer()
        type("ban", into: composer)
        _ = composer.handleKey(key(" "))

        let actions = composer.editFocusedWord()
        #expect(actions.contains { action in
            if case .showCandidates(let p) = action { return p.editHint != nil }
            return false
        })

        let expand = composer.expandFocusedCandidates()
        #expect(expand.contains { action in
            if case .showCandidates(let p) = action { return p.isExpanded }
            return false
        })
    }

    @Test("Committing from outside while retyping a word leaves no stale edit state")
    func commitDuringEditClearsEditState() {
        let composer = makeComposer()
        _ = type("chao ban ", into: composer)
        let opt = ComposerModifiers.option
        _ = composer.handleKey(ComposerKey(keyCode: 123, characters: nil, modifiers: opt))
        let began = composer.handleKey(ComposerKey(keyCode: 14, characters: "´", modifiers: opt))
        #expect(began.handled)
        _ = type("xy", into: composer)
        _ = composer.commitAll()
        _ = type("toi di", into: composer)
        #expect(VNIEngine.stripDiacritics(composer.markedText).lowercased() == "toi di", "got: \(composer.markedText)")
    }

    // MARK: - Correction Log

    @Test("Picking a candidate logs the clause pair and the word it replaced")
    func candidatePickIsLogged() {
        let composer = makeComposer()
        _ = type("ban", into: composer)
        let space = composer.handleKey(key(" "))
        guard let shown = presentation(in: space.actions), shown.alternative.candidates.count > 1 else {
            Issue.record("expected an ambiguous first word with alternatives")
            return
        }
        let before = composer.markedText.trimmingCharacters(in: .whitespaces)
        let original = shown.alternative.candidates[0]
        let replacement = shown.alternative.candidates[1]

        // ⌥2 picks the second candidate of the focused word.
        let applied = composer.handleKey(ComposerKey(keyCode: 19, characters: "2", modifiers: [.option]))

        let events = correctionEvents(in: applied.actions)
        #expect(events.count == 1)
        let event = events[0]
        #expect(event.action == .candidatePick)
        #expect(event.rawClause == "ban")
        #expect(event.wordIndex == 0)
        #expect(event.baseWord == "ban")
        #expect(event.localOutput == before)
        #expect(event.finalOutput == composer.markedText.trimmingCharacters(in: .whitespaces))
        #expect(event.wrongSurface == original)
        #expect(event.rightSurface == replacement)
        #expect(event.appBundleID.isEmpty, "the adapter fills the bundle id")
    }

    @Test("Option+Escape logs a revert_clause event with the raw clause as the final text")
    func revertClauseIsLogged() {
        let composer = makeComposer()
        _ = type("hom nay", into: composer)

        let revert = composer.handleKey(ComposerKey(keyCode: 53, characters: "\u{1B}", modifiers: [.option]))

        let events = correctionEvents(in: revert.actions)
        #expect(events.count == 1)
        #expect(events.first?.action == .revertClause)
        #expect(events.first?.rawClause == "hom nay")
        #expect(events.first?.finalOutput == "hom nay")
        #expect(events.first?.localOutput == "hôm nay")
    }

    @Test("Inline VNI logs the base word that was typed and the surface it became")
    func inlineVNIIsLogged() {
        let composer = makeComposer()
        let typed = type("ban5", into: composer)
        let events = correctionEvents(in: typed)

        #expect(events.count == 1)
        #expect(events.first?.action == .inlineVNI)
        #expect(events.first?.baseWord == "ban")
        #expect(events.first?.wrongSurface == "ban")
        #expect(events.first?.rightSurface == "bạn")
        #expect(events.first?.finalOutput == "bạn")
    }

    @Test("Option+E logs a retype event for just the retyped word")
    func retypeIsLogged() {
        let composer = makeComposer()
        _ = type("chao ban ", into: composer)
        let opt = ComposerModifiers.option
        let before = composer.markedText.trimmingCharacters(in: .whitespaces)

        // The popup already focuses the last word after Space, so ⌥E edits it directly.
        let began = composer.handleKey(ComposerKey(keyCode: 14, characters: "´", modifiers: opt))
        #expect(began.handled)

        var typingActions: [ComposerAction] = []
        for ch in "bn" { typingActions += composer.handleKey(key(ch)).actions }
        #expect(correctionEvents(in: typingActions).isEmpty, "nothing is logged until the retype is confirmed")

        let confirmed = composer.handleKey(ComposerKey(keyCode: 36, characters: "\r"))

        let events = correctionEvents(in: confirmed.actions)
        #expect(events.count == 1)
        let event = events[0]
        #expect(event.action == .retype)
        #expect(event.rawClause == "chao ban")
        #expect(event.localOutput == before)
        #expect(event.rightSurface == "bn")
        #expect(event.wrongSurface == "bạn")
        #expect(event.finalOutput == "chào bn")
    }

    @Test("Rejecting a Gemini change logs one reject_gemini event per changed word")
    func rejectGeminiIsLogged() {
        let composer = makeComposer(AppConfig(brainStrategy: .cloudFirst, geminiAPIKey: "test-key"))
        _ = type("hom nay", into: composer)
        let space = composer.handleKey(key(" "))
        guard let request = scheduledRequest(in: space.actions) else {
            Issue.record("expected a scheduled refinement")
            return
        }
        _ = composer.applyRefinement(refinementResult(request.raw, "hôm này"), for: request)

        let revert = composer.handleKey(ComposerKey(keyCode: 53, characters: "\u{1B}", modifiers: [.option]))

        let events = correctionEvents(in: revert.actions)
        #expect(events.count == 1)
        #expect(events.first?.action == .rejectGemini)
        #expect(events.first?.wordIndex == 1)
        #expect(events.first?.wrongSurface == "này")
        #expect(events.first?.rightSurface == "nay")
        #expect(events.first?.geminiOutput == "hôm này")
    }

    @Test("With the correction log disabled no events are emitted")
    func disabledLogEmitsNothing() {
        let composer = makeComposer(AppConfig(brainStrategy: .offlineOnly, correctionLogEnabled: false))
        let typed = type("ban5", into: composer)
        #expect(correctionEvents(in: typed).isEmpty)


        let revertComposer = makeComposer(AppConfig(brainStrategy: .offlineOnly, correctionLogEnabled: false))
        _ = type("hom nay", into: revertComposer)
        let revert = revertComposer.handleKey(ComposerKey(keyCode: 53, characters: "\u{1B}", modifiers: [.option]))
        #expect(correctionEvents(in: revert.actions).isEmpty)
    }


    @Test("Option+Left visits every word of the clause, including words the engine is sure about")
    func optionLeftVisitsEveryWord() {
        let composer = makeComposer()
        let typed = type("Va vo tu cho di het nhung ngay tho ", into: composer)
        var autoShown: Int?
        for case .showCandidates(let presentation) in typed { autoShown = presentation.alternative.wordIndex }
        let words = TextSegmenter.wordTokens(from: composer.markedText)
        #expect(words.count == 9)

        var visited: [Int] = []
        for _ in 0..<12 {
            let result = composer.handleKey(ComposerKey(keyCode: 123, characters: nil, modifiers: [.option]))
            #expect(result.handled)
            for case .showCandidates(let presentation) in result.actions {
                visited.append(presentation.alternative.wordIndex)
            }
        }
        // Walks right-to-left one word at a time from the caret (skipping only the word whose popup Space already
        // showed) and stops at the first word; nothing in between is skipped.
        let start = autoShown == 8 ? 7 : 8
        #expect(Array(visited.prefix(start + 1)) == Array((0...start).reversed()))
        #expect(visited.last == 0)

        // The focused `cho` (index 3) offers diacritic forms the engine never proposed, and ⌥1..5 applies them.
        for _ in 0..<3 {
            _ = composer.handleKey(ComposerKey(keyCode: 124, characters: nil, modifiers: [.option]))
        }
        let focus = composer.handleKey(ComposerKey(keyCode: 124, characters: nil, modifiers: [.option]))
        var shown: WordAlternative?
        for case .showCandidates(let presentation) in focus.actions { shown = presentation.alternative }
        #expect(shown?.wordIndex == 4)
        #expect((shown?.candidates.count ?? 0) > 1, "got: \(String(describing: shown?.candidates))")
    }


    @Test("Manual mode keeps a long message with symbols marked until Option+Space")
    func manualModeKeepsLongMessageMarked() {
        var config = AppConfig(brainStrategy: .offlineOnly)
        config.triggerMode = .manual
        let composer = makeComposer(config)
        let message = "Diem khac ban se thay trong Chrome va app Electron: ket qua gemini se hien khi ban go "
            + "phim ke tiep, ke ca space hay dau cham (hoac dau /) de chot cau"
        let actions = type(message, into: composer)
        #expect(commits(in: actions).isEmpty, "nothing may be committed before Option+Space")
        #expect(composer.markedText == message)

        let converted = composer.handleKey(ComposerKey(keyCode: 49, characters: " ", modifiers: [.option]))
        #expect(converted.handled)
        #expect(composer.markedText.hasPrefix("Điểm khác"), "got: \(composer.markedText)")
    }

}
