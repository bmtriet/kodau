import Foundation

/// Keyboard modifiers reported by the input method adapter for one key event.
public struct ComposerModifiers: OptionSet, Sendable {
    public let rawValue: UInt

    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    public static let shift = ComposerModifiers(rawValue: 1 << 0)
    public static let option = ComposerModifiers(rawValue: 1 << 1)
    public static let command = ComposerModifiers(rawValue: 1 << 2)
    public static let control = ComposerModifiers(rawValue: 1 << 3)
}

/// A single key-down event translated out of AppKit/IMK.
public struct ComposerKey: Sendable {
    /// macOS virtual key code (e.g. 49 for Space, 51 for Backspace, 36 for Return).
    public var keyCode: UInt16
    /// Printable characters produced by the key, when any.
    public var characters: String?
    /// Modifier flags for this event.
    public var modifiers: ComposerModifiers
    /// True when the OS delivered this as an auto-repeat of a held key.
    public var isRepeat: Bool

    public init(
        keyCode: UInt16,
        characters: String? = nil,
        modifiers: ComposerModifiers = [],
        isRepeat: Bool = false
    ) {
        self.keyCode = keyCode
        self.characters = characters
        self.modifiers = modifiers
        self.isRepeat = isRepeat
    }
}

/// A deferred conversion the adapter should run with `SmartCoordinator.convertSmart` and then feed back into
/// `SmartComposer.applyRefinement`.
public struct RefinementRequest: Equatable, Sendable {
    /// Raw ASCII clause that was being composed when the refinement was requested.
    public var raw: String
    /// Committed text before this clause, used as cross-clause context.
    public var context: String
    /// `clauseVersion` at request time; results for any other version are stale and discarded.
    public var version: UInt64
    /// Milliseconds the adapter should wait before calling `convertSmart`.
    public var delayMs: Int
    /// Manual conversion: skip the "should ask Gemini" gate and pass `forceSmartEngine: true`.
    public var force: Bool

    public init(raw: String, context: String, version: UInt64, delayMs: Int, force: Bool) {
        self.raw = raw
        self.context = context
        self.version = version
        self.delayMs = delayMs
        self.force = force
    }
}

/// One word that Gemini changed in a refinement. Used to explain the change in the popup and to undo it.
public struct GeminiChange: Equatable, Sendable {
    /// 0-based word index in the clause.
    public var wordIndex: Int
    /// Surface shown before the refinement.
    public var from: String
    /// Surface produced by the refinement.
    public var to: String

    public init(wordIndex: Int, from: String, to: String) {
        self.wordIndex = wordIndex
        self.from = from
        self.to = to
    }
}

/// Everything the floating candidate popup needs for one appearance.
public struct CandidatePresentation: Equatable, Sendable {
    /// The ambiguous word the candidate actions (`⌥1..5`, click) apply to.
    public var alternative: WordAlternative
    /// UTF-16 range of the focused word in the marked text, so the adapter can underline it thicker.
    public var focusedRange: NSRange
    /// Words Gemini changed in this refinement; empty for a normal candidate popup.
    public var geminiChanges: [GeminiChange]
    /// Explicit user actions (`⌥←`/`⌥→`, `⌥Space`) show at once; automatic Space popups are debounced.
    public var showsImmediately: Bool
    /// 1-based page of the expanded (`⌥6`) list; always `1` for the normal ≤5 popup.
    public var page: Int
    /// Number of pages the expanded list is split into; `1` for the normal popup.
    public var pageCount: Int
    /// True while the popup shows the expanded “Xem thêm” (`⌥6`) list instead of the ≤5 quick candidates.
    public var isExpanded: Bool
    /// Non-nil while the user retypes the focused word (`⌥E`): the popup shows this hint instead of candidates.
    public var editHint: String?

    /// True while the popup must stay on screen regardless of the auto-hide timer (the user is choosing).
    public var keepsPopupOpen: Bool {
        isExpanded || editHint != nil
    }

    public init(
        alternative: WordAlternative,
        focusedRange: NSRange,
        geminiChanges: [GeminiChange] = [],
        showsImmediately: Bool = false,
        page: Int = 1,
        pageCount: Int = 1,
        isExpanded: Bool = false,
        editHint: String? = nil
    ) {
        self.alternative = alternative
        self.focusedRange = focusedRange
        self.geminiChanges = geminiChanges
        self.showsImmediately = showsImmediately
        self.page = page
        self.pageCount = pageCount
        self.isExpanded = isExpanded
        self.editHint = editHint
    }
}

/// Side effects the adapter applies, in order, after `handleKey`/`applyRefinement`/`commitAll`.
public enum ComposerAction: Equatable, Sendable {
    /// Replace the underlined composing text.
    case setMarked(String)
    /// Clear the composing text without inserting anything.
    case clearMarked
    /// Insert text into the client (`insertText`).
    case commit(String)
    /// Run `convertSmart` after `delayMs`, then call `applyRefinement`.
    case scheduleRefinement(RefinementRequest)
    /// Cancel any in-flight scheduled refinement.
    case cancelRefinement
    /// Fire-and-forget `convertSmart` purely for learning; result ignored.
    case backgroundDistill(raw: String, context: String)
    /// Show quick-fix alternatives (only emitted when the HUD is enabled and there is a real choice).
    case showCandidates(CandidatePresentation)
    /// Hide the quick-fix alternatives.
    case hideCandidates
    /// Ctrl+Shift+Space: advance the typing mode; the adapter persists the new config.
    case cycleTypingMode
    /// Conversion/learning state changed; the adapter notifies Kodau.app.
    case statsChanged
}

/// What `handleKey` asks the adapter to do: return `handled` from IMK and apply `actions` in order.
public struct ComposerResult: Equatable, Sendable {
    public var handled: Bool
    public var actions: [ComposerAction]

    public init(handled: Bool, actions: [ComposerAction] = []) {
        self.handled = handled
        self.actions = actions
    }
}

/// Pure composing engine for Smart (không dấu + English + inline VNI) and dedicated VNI typing.
///
/// Owns every piece of composing state that used to live in `KodauIMController`, with no AppKit / Carbon /
/// InputMethodKit dependency. The input method adapter turns `NSEvent`s into `ComposerKey`s, applies the
/// returned `ComposerAction`s, and persists config changes.
///
/// Config is read from `coordinator.config` on every call, so runtime changes (typing mode, trigger mode,
/// Gemini timing, …) take effect immediately.
public final class SmartComposer {
    private let coordinator: SmartCoordinator

    // MARK: - Composing State

    private var rawClause: String = ""
    private var displayedClause: String = ""
    private var vniWordBuffer: String = ""
    private var lockedWords: [Int: String] = [:]
    private var lastResult: ConversionResult?
    private var recentCommittedContext: String = ""
    private var clauseVersion: UInt64 = 0
    private var geminiRefinedVersion: UInt64 = 0
    private var manualConvertedVersion: UInt64 = 0

    /// Ambiguous word the candidate popup and `⌥1..5` currently act on.
    private var focusedWordIndex: Int?
    /// Synthetic alternative used when the focused word has no `WordAlternative` of its own (e.g. a typo fix).
    private var synthesizedFocusAlternative: WordAlternative?
    /// Gemini changes still active since the last refinement; `⌥Esc` reverts exactly these while non-empty.
    private var pendingGeminiChanges: [GeminiChange] = []

    /// Expanded (“Xem thêm”, `⌥6`) list for the focused word, split into pages of `expandedPageSize`.
    private struct ExpandedState {
        var wordIndex: Int
        var candidates: [String]
        /// 0-based page index.
        var page: Int
    }

    private var expandedState: ExpandedState?

    /// Inline retype (“Gõ từ khác”, `⌥E`) sub-state: which word is being retyped and the keystrokes so far.
    private var editWordIndex: Int?
    private var editBuffer: String = ""
    /// Displayed clause snapshot taken when the edit started, restored verbatim on cancel.
    private var editOriginDisplayed: String = ""

    private let maxMarkedWords = 12
    private let maxManualMarkedWords = 28
    static let expandedPageSize = 5

    private static let commitPunctuation: Set<Character> = [".", ",", "!", "?", ";", ":"]

    public init(coordinator: SmartCoordinator) {
        self.coordinator = coordinator
    }

    private var config: AppConfig { coordinator.config }

    /// True when there is an active composing buffer (Smart clause or VNI word).
    public var hasActiveBuffer: Bool {
        !rawClause.isEmpty || !vniWordBuffer.isEmpty
    }

    /// The text currently shown as marked (underlined) composing text.
    public var markedText: String {
        if let wordIndex = editWordIndex {
            // While retyping, the marked text previews the clause with the edit buffer in the word's place.
            return replacingWord(at: wordIndex, with: editBuffer, in: displayedClause)
        }
        return vniWordBuffer.isEmpty ? displayedClause : vniWordBuffer
    }

    // MARK: - Main Entry Point

    /// Processes one key-down event and returns whether the adapter must consume it.
    public func handleKey(_ key: ComposerKey) -> ComposerResult {
        // The inline retype sub-state (`⌥E`) owns every key until it confirms or cancels.
        if editWordIndex != nil {
            return handleEditKey(key)
        }

        let flags = key.modifiers
        let keyCode = key.keyCode
        var pending: [ComposerAction] = []

        // Global mode cycle shortcut: Ctrl + Shift + Space
        if keyCode == 49 && flags.contains(.control) && flags.contains(.shift) && !flags.contains(.command) {
            var actions = commitAllActions()
            actions.append(.cycleTypingMode)
            return ComposerResult(handled: true, actions: actions)
        }

        // Option + Space / Option + 1...5 / Option + Escape
        if flags.contains(.option) && !flags.contains(.command) && !flags.contains(.control) {
            // Option + Space: force conversion of the current VNI word or Smart clause. Holding the key must not
            // re-run the conversion (and its Gemini call) on every auto-repeat.
            if keyCode == 49 && !flags.contains(.shift) && config.typingMode != .english {
                guard !key.isRepeat else { return ComposerResult(handled: true) }
                if config.typingMode == .vni {
                    if triggerManualVNIConversion(into: &pending) {
                        return ComposerResult(handled: true, actions: pending)
                    }
                } else if !rawClause.isEmpty {
                    return ComposerResult(handled: true, actions: pending + triggerManualConversion())
                } else if config.triggerMode == .manual {
                    return ComposerResult(handled: true, actions: pending)
                }
            }

            // Only consume Option+1..5 when a candidate was actually applied; otherwise fall through so the
            // composition is committed before the app receives the Option-character (e.g. "¡").
            if let digitIndex = optionDigitIndex(keyCode: keyCode), !rawClause.isEmpty,
               let actions = applyAlternativeCandidate(index: digitIndex) {
                return ComposerResult(handled: true, actions: pending + actions)
            }

            // Option + Left/Right: move the popup focus between ambiguous words. Only consumed while a Smart
            // clause with real alternatives is composing; otherwise the arrow keeps its normal cursor meaning.
            if keyCode == 123 || keyCode == 124, let actions = cycleCandidateFocus(forward: keyCode == 124) {
                return ComposerResult(handled: true, actions: pending + actions)
            }

            // Option + 6 ("Xem thêm"): expand the focused word's full diacritic list, paged 5 at a time.
            if keyCode == 22, let actions = toggleExpandedCandidates() {
                return ComposerResult(handled: true, actions: pending + actions)
            }

            // Option + E ("Gõ từ khác"): retype just the focused word in place.
            if keyCode == 14, let actions = beginEditingFocusedWord() {
                return ComposerResult(handled: true, actions: pending + actions)
            }

            // Option + Escape: revert the Gemini changes in place, or the whole composing clause to raw ASCII.
            if keyCode == 53 && !rawClause.isEmpty {
                if !pendingGeminiChanges.isEmpty {
                    return ComposerResult(handled: true, actions: pending + revertGeminiChanges())
                }
                return ComposerResult(handled: true, actions: pending + revertAndCommitRawASCII())
            }
        }

        // Pass through Command / Control / Function shortcuts after committing any pending buffer
        if flags.contains(.command) || flags.contains(.control) {
            return ComposerResult(handled: false, actions: pending + commitAllActions())
        }

        // English / raw pass-through mode
        if config.typingMode == .english {
            return ComposerResult(handled: false, actions: pending + commitAllActions())
        }

        // Special keys: Backspace, Escape, Return, Tab, Arrow/Navigation keys
        switch keyCode {
        case 51: // Delete / Backspace
            return prepend(pending, handleBackspace(mode: config.typingMode))

        case 53: // Escape -> revert to raw ASCII if composing
            if !rawClause.isEmpty {
                return ComposerResult(handled: true, actions: pending + revertAndCommitRawASCII())
            }
            if !vniWordBuffer.isEmpty {
                let raw = VNIEngine.stripDiacritics(vniWordBuffer)
                var actions: [ComposerAction] = [.commit(raw)]
                resetBuffers(into: &actions)
                return ComposerResult(handled: true, actions: pending + actions)
            }
            return ComposerResult(handled: false, actions: pending)

        case 36, 76: // Return / Enter
            // Return false so the target app receives Return (sends chat message / inserts newline)
            let actions = hasActiveBuffer ? commitAllActions() : []
            return ComposerResult(handled: false, actions: pending + actions)

        case 48: // Tab
            let actions = hasActiveBuffer ? commitAllActions() : []
            return ComposerResult(handled: false, actions: pending + actions)

        case 123, 124, 125, 126, 115, 116, 117, 119, 121:
            // Arrows, Home, End, PageUp, PageDown, Forward Delete
            let actions = hasActiveBuffer ? commitAllActions() : []
            return ComposerResult(handled: false, actions: pending + actions)

        default:
            break
        }

        // Extract printable character
        guard let chars = key.characters, chars.count == 1, let ch = chars.first else {
            let actions = hasActiveBuffer ? commitAllActions() : []
            return ComposerResult(handled: false, actions: pending + actions)
        }

        // Ignore control / non-printable characters
        if let scalar = ch.unicodeScalars.first, scalar.value < 0x20 || scalar.value == 0x7F {
            let actions = hasActiveBuffer ? commitAllActions() : []
            return ComposerResult(handled: false, actions: pending + actions)
        }

        switch config.typingMode {
        case .vni:
            return prepend(pending, handleVNICharacter(ch))
        case .smart:
            return prepend(pending, handleSmartCharacter(ch))
        case .english:
            return ComposerResult(handled: false, actions: pending)
        }
    }

    private func prepend(_ pending: [ComposerAction], _ result: ComposerResult) -> ComposerResult {
        ComposerResult(handled: result.handled, actions: pending + result.actions)
    }

    // MARK: - Dedicated VNI Mode

    private func handleVNICharacter(_ ch: Character) -> ComposerResult {
        if ch.isLetter || ch.isNumber {
            let result = coordinator.vniEngine.processKey(currentWord: vniWordBuffer, key: ch)
            // Every keystroke that changes the VNI buffer invalidates any in-flight refinement (e.g. the one
            // scheduled by `triggerManualVNIConversion`), otherwise a stale result could overwrite newer input.
            clauseVersion &+= 1
            vniWordBuffer = result.newWord
            return ComposerResult(handled: true, actions: [.setMarked(vniWordBuffer)])
        }

        // Delimiter (space or punctuation): commit VNI word + delimiter
        if !vniWordBuffer.isEmpty {
            let finalized = vniWordBuffer
            var actions: [ComposerAction] = [.commit(finalized + String(ch))]
            coordinator.learnFromVNIWord(finalized, precedingContext: recentCommittedContext)
            appendToRecentContext(finalized)
            resetBuffers(into: &actions)
            return ComposerResult(handled: true, actions: actions)
        }

        return ComposerResult(handled: false)
    }

    /// `Option + Space` in VNI mode. VNI inserts each character straight into the app, so only the word still
    /// being composed can be rewritten safely. Words already committed on this line are left untouched.
    /// Returns `false` when there is nothing to restore so the key falls through to the normal VNI path.
    private func triggerManualVNIConversion(into actions: inout [ComposerAction]) -> Bool {
        actions.append(.cancelRefinement)

        let wordOnScreen = vniWordBuffer
        let asciiWord = VNIEngine.stripDiacritics(wordOnScreen)
        guard !wordOnScreen.isEmpty, !asciiWord.isEmpty,
              !VNIEngine.containsVietnameseDiacritics(wordOnScreen) else {
            return false
        }

        clauseVersion &+= 1
        let versionSnapshot = clauseVersion

        let localRes = coordinator.convertSync(
            asciiWord,
            precedingContext: recentCommittedContext,
            forceSmartEngine: true
        )
        let restoredWord = localRes.convertedText
        guard restoredWord != wordOnScreen else { return false }

        vniWordBuffer = restoredWord
        lastResult = localRes
        manualConvertedVersion = versionSnapshot
        actions.append(.setMarked(restoredWord))

        let cfg = config
        if cfg.hasAPIKey && cfg.brainStrategy != .offlineOnly {
            actions.append(.scheduleRefinement(RefinementRequest(
                raw: asciiWord,
                context: recentCommittedContext,
                version: versionSnapshot,
                delayMs: 0,
                force: true
            )))
        } else {
            // The restored word is learned when the VNI word is committed, so only telemetry here.
            coordinator.store.recordConversionEvent(source: localRes.source)
            actions.append(.statsChanged)
        }

        return true
    }

    // MARK: - Smart Mode (Auto Vietnamese Không Dấu + English + Inline VNI)

    private func handleSmartCharacter(_ ch: Character) -> ComposerResult {
        let cfg = config

        // 1. Space
        if ch == " " {
            if rawClause.isEmpty {
                return ComposerResult(handled: false)
            }

            // Manual Trigger Mode: keep raw text untouched in marked buffer until Option+Space
            if cfg.triggerMode == .manual {
                rawClause.append(" ")
                displayedClause.append(" ")
                clauseVersion &+= 1
                var actions: [ComposerAction] = [.setMarked(displayedClause)]

                let words = rawClause.split(whereSeparator: { $0.isWhitespace })
                if words.count >= maxManualMarkedWords {
                    actions += commitAllActions()
                }
                return ComposerResult(handled: true, actions: actions)
            }

            // Avoid double space issues; if already ends with space, commit and pass space through
            if rawClause.hasSuffix(" ") {
                return ComposerResult(handled: false, actions: commitAllActions())
            }

            rawClause.append(" ")
            clauseVersion &+= 1
            pendingGeminiChanges = []
            expandedState = nil
            let localRes = runLocalConversionPreservingLocks(raw: rawClause)
            displayedClause = localRes.convertedText
            lastResult = localRes
            focusedWordIndex = realAlternatives(in: localRes).last?.wordIndex
            synthesizedFocusAlternative = nil
            var actions: [ComposerAction] = [.setMarked(displayedClause)]

            // Only nag about the word the user just finished; older ambiguous words stay available via `⌥←/→`.
            let completedWordIndex = wordCount(in: rawClause) - 1
            if let focused = focusedAlternative, focused.wordIndex == completedWordIndex,
               let candidate = candidatePresentation(for: focused, showsImmediately: false) {
                actions.append(candidate)
            } else {
                actions.append(.hideCandidates)
            }

            // If clause is getting long, commit completed prefix so marked text stays sleek
            let words = rawClause.split(whereSeparator: { $0.isWhitespace })
            if words.count >= maxMarkedWords {
                actions += commitAllActions()
                return ComposerResult(handled: true, actions: actions)
            }

            // Schedule debounced Gemini refinement when appropriate
            actions += scheduleGeminiIfNeeded(
                rawSnapshot: rawClause,
                localResult: localRes,
                versionSnapshot: clauseVersion
            )
            return ComposerResult(handled: true, actions: actions)
        }

        // 2. Sentence-ending or clause punctuation
        if Self.commitPunctuation.contains(ch) {
            if rawClause.isEmpty {
                return ComposerResult(handled: false)
            }

            // Manual Trigger Mode:
            // - If user ALREADY pressed Option+Space on this clause, commit the converted text + punctuation.
            // - Otherwise keep raw text + punctuation untouched in marked buffer so Option+Space can convert the whole sentence!
            if cfg.triggerMode == .manual {
                let alreadyConverted = (manualConvertedVersion == clauseVersion || geminiRefinedVersion == clauseVersion)
                if alreadyConverted {
                    var actions: [ComposerAction] = [.cancelRefinement]
                    if geminiRefinedVersion != clauseVersion, let res = lastResult {
                        coordinator.store.recordConversionEvent(source: res.source)
                    }
                    let finalText = displayedClause
                    actions.append(.commit(finalText + String(ch)))
                    appendToRecentContext(finalText)
                    resetBuffers(into: &actions)
                    return ComposerResult(handled: true, actions: actions)
                }
                rawClause.append(ch)
                displayedClause.append(ch)
                clauseVersion &+= 1
                pendingGeminiChanges = []
                return ComposerResult(handled: true, actions: [.setMarked(displayedClause)])
            }

            var actions: [ComposerAction] = [.cancelRefinement]

            let wasGeminiRefined = (geminiRefinedVersion == clauseVersion)
            let finalLocal = runLocalConversionPreservingLocks(raw: rawClause)
            let finalText = (wasGeminiRefined && !displayedClause.isEmpty)
                ? displayedClause
                : finalLocal.convertedText

            let rawSnapshot = rawClause
            let ctxSnapshot = recentCommittedContext

            actions.append(.commit(finalText + String(ch)))
            coordinator.store.recordConversionEvent(source: finalLocal.source)
            appendToRecentContext(finalText)
            resetBuffers(into: &actions)

            // Silent background distillation if Gemini hasn't seen this ambiguous clause yet
            if shouldAskGemini(localResult: finalLocal, config: cfg) && !wasGeminiRefined {
                actions.append(.backgroundDistill(raw: rawSnapshot, context: ctxSnapshot))
            }
            return ComposerResult(handled: true, actions: actions)
        }

        // 3. Inline VNI digit override inside Smart Mode (e.g., `tie6ng1`, `ban5`, `tu72`, `dau61`, `d9uoc75`)
        if ch.isNumber && cfg.inlineVNIOverrideEnabled && !rawClause.isEmpty && !rawClause.hasSuffix(" ") {
            let (rawPrefix, _) = splitLastWord(rawClause)
            let (dispPrefix, dispTail) = splitLastWord(displayedClause)
            let candidateDisp = dispTail + String(ch)

            if !dispTail.isEmpty && coordinator.vniEngine.looksLikeInlineVNI(candidateDisp) {
                let vniRes = coordinator.vniEngine.processKey(currentWord: dispTail, key: ch)
                if vniRes.didTransform {
                    clauseVersion &+= 1
                    pendingGeminiChanges = []
                    focusedWordIndex = nil
                    synthesizedFocusAlternative = nil
                    expandedState = nil

                    let wordIdx = wordCount(in: rawPrefix)
                    let baseAscii = VNIEngine.stripDiacritics(vniRes.newWord).lowercased()
                    rawClause = rawPrefix + baseAscii
                    displayedClause = dispPrefix + vniRes.newWord
                    lockedWords[wordIdx] = vniRes.newWord

                    // Immediately teach LearningStore with userVerified = true!
                    let prevWords = dispPrefix.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                    coordinator.store.recordUserCorrection(
                        baseWord: baseAscii,
                        chosenSurface: vniRes.newWord,
                        prev1: prevWords.last?.lowercased(),
                        prev2: prevWords.count >= 2 ? prevWords[prevWords.count - 2].lowercased() : nil
                    )
                    return ComposerResult(handled: true, actions: [.cancelRefinement, .hideCandidates, .setMarked(displayedClause)])
                }
            }
        }

        // 4. Normal character (letters, digits, apostrophe, hyphen, underscore)
        if ch.isLetter || ch.isNumber || ch == "'" || ch == "-" || ch == "_" {
            clauseVersion &+= 1
            pendingGeminiChanges = []
            synthesizedFocusAlternative = nil
            expandedState = nil
            rawClause.append(ch)
            displayedClause.append(ch)
            syncLockOfWordStillBeingTyped()
            return ComposerResult(handled: true, actions: [.cancelRefinement, .hideCandidates, .setMarked(displayedClause)])
        }

        // 5. Any other symbol (e.g., quotes, brackets, operators): commit current clause and let symbol pass through
        if hasActiveBuffer {
            return ComposerResult(handled: false, actions: commitAllActions())
        }
        return ComposerResult(handled: false)
    }

    // MARK: - Backspace & Candidate Picking

    private func handleBackspace(mode: TypingMode) -> ComposerResult {
        if mode == .vni {
            guard !vniWordBuffer.isEmpty else { return ComposerResult(handled: false) }
            clauseVersion &+= 1
            vniWordBuffer.removeLast()
            if vniWordBuffer.isEmpty {
                return ComposerResult(handled: true, actions: [.clearMarked])
            }
            return ComposerResult(handled: true, actions: [.setMarked(vniWordBuffer)])
        }

        guard !rawClause.isEmpty else { return ComposerResult(handled: false) }

        clauseVersion &+= 1
        pendingGeminiChanges = []
        focusedWordIndex = nil
        synthesizedFocusAlternative = nil
        expandedState = nil

        rawClause.removeLast()
        if !displayedClause.isEmpty {
            displayedClause.removeLast()
        }

        // Drop locks beyond the current word count
        let currentWords = wordCount(in: rawClause)
        lockedWords = lockedWords.filter { $0.key < currentWords }

        if rawClause.isEmpty {
            var actions: [ComposerAction] = [.cancelRefinement]
            resetBuffers(into: &actions)
            actions.append(.clearMarked)
            return ComposerResult(handled: true, actions: actions)
        }

        // Re-sync displayed clause cleanly if lengths diverged
        if displayedClause.count != rawClause.count {
            if config.triggerMode == .manual {
                displayedClause = applyLockedWords(to: rawClause)
            } else {
                let res = runLocalConversionPreservingLocks(raw: rawClause)
                displayedClause = res.convertedText
                lastResult = res
            }
        }
        return ComposerResult(handled: true, actions: [.cancelRefinement, .hideCandidates, .setMarked(displayedClause)])
    }

    private func applyAlternativeCandidate(index: Int) -> [ComposerAction]? {
        guard let alt = focusedAlternative ?? realAlternatives(in: lastResult).last else {
            return nil
        }

        // In the expanded (`⌥6`) list, `⌥1..5` picks from the currently shown page instead of the quick list.
        let chosen: String
        if let expanded = expandedState, expanded.wordIndex == alt.wordIndex {
            let offset = expanded.page * Self.expandedPageSize + index
            guard index >= 0, index < Self.expandedPageSize, offset < expanded.candidates.count else {
                return nil
            }
            chosen = expanded.candidates[offset]
        } else {
            guard index >= 0, index < alt.candidates.count else { return nil }
            chosen = alt.candidates[index]
        }

        let updated = coordinator.applyUserCorrection(
            rawClause: rawClause,
            currentConverted: displayedClause,
            wordIndex: alt.wordIndex,
            chosenWord: chosen
        )
        lockedWords[alt.wordIndex] = chosen
        displayedClause = updated
        clauseVersion &+= 1
        focusedWordIndex = alt.wordIndex
        pendingGeminiChanges = []
        synthesizedFocusAlternative = nil
        expandedState = nil
        return [.cancelRefinement, .hideCandidates, .setMarked(displayedClause)]
    }

    /// Applies a candidate clicked in the floating quick-fix popup. Same effect as `⌥1..5` for the focused
    /// word, including teaching the LearningStore, and hides the popup.
    public func selectCandidate(_ surface: String) -> [ComposerAction] {
        guard let alt = focusedAlternative ?? realAlternatives(in: lastResult).last else { return [] }

        // The expanded list may contain surfaces the quick list does not; resolve the index from whichever
        // candidate set currently backs the popup and then apply it through the normal path.
        if let expanded = expandedState, expanded.wordIndex == alt.wordIndex,
           let offset = expanded.candidates.firstIndex(where: { $0.lowercased() == surface.lowercased() }) {
            let page = offset / Self.expandedPageSize
            expandedState?.page = page
            return applyAlternativeCandidate(index: offset % Self.expandedPageSize) ?? []
        }

        let target = surface.lowercased()
        guard let index = alt.candidates.firstIndex(where: { $0.lowercased() == target }) else { return [] }
        return applyAlternativeCandidate(index: index) ?? []
    }

    /// The popup's undo button: reverts only the pending Gemini changes when there are any, otherwise falls back
    /// to the whole-clause `⌥Esc` behaviour.
    public func undoCandidatePopup() -> [ComposerAction] {
        if !pendingGeminiChanges.isEmpty {
            return revertGeminiChanges()
        }
        return revertToRaw()
    }

    /// Reverts the composing clause to the raw ASCII text and teaches the store — same as `⌥Esc`.
    public func revertToRaw() -> [ComposerAction] {
        guard !rawClause.isEmpty else { return [] }
        return revertAndCommitRawASCII()
    }

    private func revertAndCommitRawASCII() -> [ComposerAction] {
        var actions: [ComposerAction] = [.cancelRefinement]
        let raw = rawClause
        actions.append(.commit(raw))

        // Teach LearningStore that the user explicitly wanted these words kept as raw ASCII / English
        let tokens = raw.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        for (idx, token) in tokens.enumerated() {
            let base = VNIEngine.stripDiacritics(token).lowercased()
            guard !base.isEmpty else { continue }
            let p1 = idx > 0 ? tokens[idx - 1].lowercased() : nil
            let p2 = idx > 1 ? tokens[idx - 2].lowercased() : nil
            coordinator.store.recordUserCorrection(
                baseWord: base,
                chosenSurface: token.lowercased(),
                prev1: p1,
                prev2: p2,
                next1: idx + 1 < tokens.count ? tokens[idx + 1] : nil,
                fullRawClause: raw,
                fullCorrectedClause: raw
            )
        }

        appendToRecentContext(raw)
        resetBuffers(into: &actions)
        return actions
    }

    // MARK: - Local + Async Gemini Refinement

    /// Triggered by Option+Space: immediately converts the current `rawClause` (Local + 0ms Gemini if configured).
    private func triggerManualConversion() -> [ComposerAction] {
        var actions: [ComposerAction] = [.cancelRefinement]

        let trimmed = rawClause.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return actions }

        clauseVersion &+= 1
        pendingGeminiChanges = []
        expandedState = nil
        let versionSnapshot = clauseVersion

        let localRes = runLocalConversionPreservingLocks(raw: rawClause)
        displayedClause = localRes.convertedText
        lastResult = localRes
        manualConvertedVersion = versionSnapshot
        focusedWordIndex = realAlternatives(in: localRes).last?.wordIndex
        synthesizedFocusAlternative = nil
        actions.append(.setMarked(displayedClause))
        if let focused = focusedAlternative,
           let candidate = candidatePresentation(for: focused, showsImmediately: true) {
            actions.append(candidate)
        } else {
            actions.append(.hideCandidates)
        }

        let cfg = config
        if cfg.hasAPIKey && cfg.brainStrategy != .offlineOnly {
            actions += scheduleGeminiIfNeeded(
                rawSnapshot: rawClause,
                localResult: localRes,
                versionSnapshot: versionSnapshot,
                delayMsOverride: 0,
                forceRun: true
            )
        }
        // Offline conversions are recorded once at commit time (see `commitAll`),
        // so we do not record here to avoid double-counting stats.
        return actions
    }

    private func runLocalConversionPreservingLocks(raw: String) -> ConversionResult {
        let baseResult = coordinator.convertSync(raw, precedingContext: recentCommittedContext)
        guard !lockedWords.isEmpty else { return baseResult }
        let merged = applyLockedWords(to: baseResult.convertedText)
        return ConversionResult(
            originalText: baseResult.originalText,
            convertedText: merged,
            confidence: baseResult.confidence,
            source: baseResult.source,
            vietnameseRatio: baseResult.vietnameseRatio,
            alternatives: baseResult.alternatives,
            latencyMs: baseResult.latencyMs
        )
    }

    private func shouldAskGemini(localResult: ConversionResult, config: AppConfig) -> Bool {
        guard config.hasAPIKey else { return false }
        guard config.brainStrategy != .offlineOnly else { return false }
        // Never bother Gemini for pure English sentences detected with high confidence
        if localResult.source == .localEnglish && localResult.confidence >= 0.85 {
            return false
        }
        if config.brainStrategy == .cloudFirst {
            return true
        }
        return localResult.confidence < config.localConfidenceThreshold
    }

    private func scheduleGeminiIfNeeded(
        rawSnapshot: String,
        localResult: ConversionResult,
        versionSnapshot: UInt64,
        delayMsOverride: Int? = nil,
        forceRun: Bool = false
    ) -> [ComposerAction] {
        let cfg = config
        if !forceRun {
            guard shouldAskGemini(localResult: localResult, config: cfg) else { return [] }
        } else {
            guard cfg.hasAPIKey && cfg.brainStrategy != .offlineOnly else { return [] }
        }

        // Per-sentence timing waits for a real typing pause mid-sentence; punctuation / Return commit locally and
        // distill with Gemini once in the background, so each sentence costs about one call.
        let defaultDelayMs = cfg.geminiTiming == .perSentence
            ? max(500, cfg.sentencePauseMilliseconds)
            : max(120, cfg.debounceMilliseconds)
        let effectiveDelayMs = delayMsOverride ?? defaultDelayMs

        let request = RefinementRequest(
            raw: rawSnapshot,
            context: recentCommittedContext,
            version: versionSnapshot,
            delayMs: effectiveDelayMs,
            force: forceRun
        )
        return [.cancelRefinement, .scheduleRefinement(request)]
    }

    /// Applies a conversion produced by the adapter's scheduled `convertSmart` call.
    ///
    /// Results whose `version` no longer matches `clauseVersion` are discarded. The adapter is responsible for
    /// emitting `.statsChanged` after the conversion itself (the old controller notified before this guard).
    public func applyRefinement(_ result: ConversionResult, for request: RefinementRequest) -> [ComposerAction] {
        guard request.version == clauseVersion else { return [] }

        // VNI mode rewrites the word still on screen; Smart mode rewrites the whole marked clause.
        if request.force && !vniWordBuffer.isEmpty {
            vniWordBuffer = result.convertedText
            lastResult = result
            geminiRefinedVersion = request.version
            return [.setMarked(vniWordBuffer)]
        }

        let trailingSpacesCount = request.raw.reversed().prefix(while: { $0 == " " }).count
        let trailingSpaces = String(repeating: " ", count: trailingSpacesCount)
        let previousDisplayed = displayedClause
        expandedState = nil
        let merged = applyLockedWords(to: result.convertedText) + trailingSpaces
        displayedClause = merged
        lastResult = result
        geminiRefinedVersion = request.version

        var actions: [ComposerAction] = [.setMarked(merged)]
        var didShowCandidate = false

        // Part C: explain what Gemini changed and let the user reject just those words.
        let changes = Self.diffWords(previous: previousDisplayed, new: merged)
        if let focusIndex = changes.map(\.wordIndex).max() {
            pendingGeminiChanges = changes
            focusedWordIndex = focusIndex
            let alternative = alternativeForChangedWord(at: focusIndex, in: merged, result: result)
            synthesizedFocusAlternative = result.alternatives.contains { $0.wordIndex == focusIndex }
                ? nil
                : alternative
            if let candidate = candidatePresentation(
                for: alternative,
                geminiChanges: changes,
                showsImmediately: true
            ) {
                actions.append(candidate)
                didShowCandidate = true
            }
        } else {
            // No change from Gemini: only surface an ambiguity the user just finished typing.
            pendingGeminiChanges = []
            synthesizedFocusAlternative = nil
            focusedWordIndex = realAlternatives(in: result).last?.wordIndex
            let completedWordIndex = wordCount(in: rawClause) - 1
            if let focused = focusedAlternative, focused.wordIndex == completedWordIndex,
               let candidate = candidatePresentation(for: focused, showsImmediately: true) {
                actions.append(candidate)
                didShowCandidate = true
            }
        }
        if !didShowCandidate {
            actions.append(.hideCandidates)
        }
        return actions
    }

    // MARK: - Commit & Marked Text Helpers

    /// Commits the active composing buffer (for `commitComposition` / `deactivateServer`).
    public func commitAll() -> [ComposerAction] {
        commitAllActions()
    }

    private func commitAllActions() -> [ComposerAction] {
        var actions: [ComposerAction] = [.cancelRefinement]

        if !vniWordBuffer.isEmpty {
            let word = vniWordBuffer
            actions.append(.commit(word))
            coordinator.learnFromVNIWord(word, precedingContext: recentCommittedContext)
            appendToRecentContext(word)
            resetBuffers(into: &actions)
            return actions
        }

        if !rawClause.isEmpty {
            let cfg = config
            let rawSnapshot = rawClause
            let ctxSnapshot = recentCommittedContext
            let wasGeminiRefined = (geminiRefinedVersion == clauseVersion)
            let wasManuallyConverted = (manualConvertedVersion == clauseVersion)

            // In Manual Trigger Mode: commit raw text untouched UNLESS user already pressed Option+Space
            if cfg.triggerMode == .manual {
                let textToCommit = !displayedClause.isEmpty ? displayedClause : rawSnapshot
                if wasManuallyConverted && !wasGeminiRefined, let res = lastResult {
                    coordinator.store.recordConversionEvent(source: res.source)
                }
                actions.append(.commit(textToCommit))
                appendToRecentContext(textToCommit)
                resetBuffers(into: &actions)
                return actions
            }

            // In Automatic Mode: synchronously convert before commit
            let textToCommit: String
            var localResForDistill: ConversionResult?
            if wasGeminiRefined && !displayedClause.isEmpty {
                textToCommit = displayedClause
            } else {
                let res = runLocalConversionPreservingLocks(raw: rawSnapshot)
                localResForDistill = res
                textToCommit = res.convertedText
                coordinator.store.recordConversionEvent(source: res.source)
            }
            actions.append(.commit(textToCommit))
            appendToRecentContext(textToCommit)
            resetBuffers(into: &actions)

            // Silently distill & learn with Gemini in background if needed and not yet refined
            if !wasGeminiRefined,
               let localRes = localResForDistill,
               shouldAskGemini(localResult: localRes, config: cfg) {
                actions.append(.backgroundDistill(raw: rawSnapshot, context: ctxSnapshot))
            }
        }

        return actions
    }

    private func resetBuffers(into actions: inout [ComposerAction]) {
        rawClause = ""
        displayedClause = ""
        vniWordBuffer = ""
        lockedWords = [:]
        lastResult = nil
        clauseVersion &+= 1
        geminiRefinedVersion = 0
        manualConvertedVersion = 0
        focusedWordIndex = nil
        synthesizedFocusAlternative = nil
        pendingGeminiChanges = []
        expandedState = nil
        // A commit from outside (focus change, click) while retyping a word keeps the original word.
        editWordIndex = nil
        editBuffer = ""
        editOriginDisplayed = ""
        actions.append(.hideCandidates)
        actions.append(.statsChanged)
    }

    private func appendToRecentContext(_ text: String) {
        let combined = (recentCommittedContext + " " + text)
            .split(whereSeparator: { $0.isWhitespace })
            .suffix(4)
            .joined(separator: " ")
        recentCommittedContext = combined
    }

    // MARK: - Candidate Focus

    /// Ambiguous words (`>1` candidate) sorted by word index; the default focus is the last one.
    private func realAlternatives(in result: ConversionResult?) -> [WordAlternative] {
        guard let result else { return [] }
        return result.alternatives
            .filter { $0.candidates.count > 1 }
            .sorted { $0.wordIndex < $1.wordIndex }
    }

    /// The word the popup and `⌥1..5` act on. Falls back to a synthetic alternative for changed words that have
    /// no entry in the conversion result.
    private var focusedAlternative: WordAlternative? {
        guard let focusedWordIndex else { return nil }
        if let match = lastResult?.alternatives.first(where: { $0.wordIndex == focusedWordIndex }) {
            return match
        }
        if let synthesizedFocusAlternative, synthesizedFocusAlternative.wordIndex == focusedWordIndex {
            return synthesizedFocusAlternative
        }
        return nil
    }

    private func candidatePresentation(
        for alternative: WordAlternative,
        geminiChanges: [GeminiChange] = [],
        showsImmediately: Bool
    ) -> ComposerAction? {
        guard config.showCandidateHUD else { return nil }
        let range = utf16Range(ofWordAt: alternative.wordIndex, in: displayedClause)
            ?? NSRange(location: (displayedClause as NSString).length, length: 0)

        // A popup shown for a different word drops any expanded/edit state from the previous one.
        if let expanded = expandedState, expanded.wordIndex != alternative.wordIndex {
            expandedState = nil
        }

        if let expanded = expandedState, expanded.wordIndex == alternative.wordIndex {
            let pageCount = max(1, (expanded.candidates.count + Self.expandedPageSize - 1) / Self.expandedPageSize)
            let page = min(max(0, expanded.page), pageCount - 1)
            let start = page * Self.expandedPageSize
            let end = min(start + Self.expandedPageSize, expanded.candidates.count)
            let pageCandidates = start < end ? Array(expanded.candidates[start..<end]) : []
            return .showCandidates(CandidatePresentation(
                alternative: WordAlternative(
                    wordIndex: alternative.wordIndex,
                    baseWord: alternative.baseWord,
                    selected: alternative.selected,
                    candidates: pageCandidates
                ),
                focusedRange: range,
                geminiChanges: geminiChanges,
                showsImmediately: showsImmediately,
                page: page + 1,
                pageCount: pageCount,
                isExpanded: true
            ))
        }

        return .showCandidates(CandidatePresentation(
            alternative: alternative,
            focusedRange: range,
            geminiChanges: geminiChanges,
            showsImmediately: showsImmediately
        ))
    }

    /// `⌥←` / `⌥→`: step the focus between ambiguous words and show the popup for the new one. Returns `nil`
    /// when there is nothing to cycle, so the adapter does not consume the arrow.
    private func cycleCandidateFocus(forward: Bool) -> [ComposerAction]? {
        guard config.showCandidateHUD else { return nil }
        guard !rawClause.isEmpty else { return nil }
        let alternatives = realAlternatives(in: lastResult)
        guard !alternatives.isEmpty else { return nil }

        let nextPosition: Int
        if let current = alternatives.firstIndex(where: { $0.wordIndex == focusedWordIndex }) {
            nextPosition = forward ? min(current + 1, alternatives.count - 1) : max(current - 1, 0)
        } else {
            nextPosition = forward ? 0 : alternatives.count - 1
        }

        let alternative = alternatives[nextPosition]
        focusedWordIndex = alternative.wordIndex
        synthesizedFocusAlternative = nil
        expandedState = nil
        guard let candidate = candidatePresentation(
            for: alternative,
            geminiChanges: pendingGeminiChanges,
            showsImmediately: true
        ) else {
            return []
        }
        return [candidate]
    }

    // MARK: - Expanded Candidates ("Xem thêm", ⌥6)

    /// Words online in the expanded list: every valid diacritic form of the focused word, its current
    /// candidates first. Empty when no word is focused or the word has nothing more to offer.
    private func expandedCandidates(for alternative: WordAlternative) -> [String] {
        guard !alternative.baseWord.isEmpty else { return [] }
        let currentSelected = TextSegmenter.wordTokens(from: displayedClause)
        let rawWord: String
        if alternative.wordIndex < currentSelected.count {
            rawWord = currentSelected[alternative.wordIndex]
        } else {
            rawWord = alternative.selected
        }
        return DiacriticVariants.all(
            for: alternative.baseWord,
            rawCasing: rawWord,
            currentCandidates: alternative.candidates,
            preferFirstVowel: config.modernTonePlacement
        )
    }

    /// `⌥6`: open the expanded list for the focused word, or advance to the next page (wrapping). Returns `nil`
    /// when no word is focused (or nothing can be expanded), so the adapter does not consume the key.
    private func toggleExpandedCandidates() -> [ComposerAction]? {
        guard config.showCandidateHUD, !rawClause.isEmpty else { return nil }
        guard let alternative = focusedAlternative else { return nil }

        if let expanded = expandedState, expanded.wordIndex == alternative.wordIndex {
            let pageCount = max(1, (expanded.candidates.count + Self.expandedPageSize - 1) / Self.expandedPageSize)
            expandedState?.page = (expanded.page + 1) % pageCount
        } else {
            let candidates = expandedCandidates(for: alternative)
            guard candidates.count > 1 else { return nil }
            expandedState = ExpandedState(wordIndex: alternative.wordIndex, candidates: candidates, page: 0)
        }

        guard let candidate = candidatePresentation(
            for: alternative,
            geminiChanges: pendingGeminiChanges,
            showsImmediately: true
        ) else {
            return []
        }
        return [candidate]
    }

    /// The popup's “Thêm…” chip: same effect as `⌥6`.
    public func expandFocusedCandidates() -> [ComposerAction] {
        toggleExpandedCandidates() ?? []
    }

    // MARK: - Inline Word Retype ("Gõ từ khác", ⌥E)

    /// `⌥E`: start retyping the focused word in place. Returns `nil` when no word is focused (or the clause is
    /// empty), so the adapter passes the key on.
    private func beginEditingFocusedWord() -> [ComposerAction]? {
        guard config.showCandidateHUD, !rawClause.isEmpty, let wordIndex = focusedWordIndex else {
            return nil
        }
        guard wordIndex < wordCount(in: displayedClause) else { return nil }
        guard let alternative = focusedAlternative ?? alternativeForEditing(at: wordIndex) else { return nil }

        editWordIndex = wordIndex
        editBuffer = ""
        editOriginDisplayed = displayedClause
        expandedState = nil
        // Discard any in-flight refinement so a late result cannot rewrite the clause under the edit preview.
        clauseVersion &+= 1
        var actions: [ComposerAction] = [.cancelRefinement]
        if let shown = editPresentation(for: alternative, showsImmediately: true) {
            actions.append(shown)
        }
        return actions
    }

    /// The popup's “Gõ từ khác” chip: same effect as `⌥E`.
    public func editFocusedWord() -> [ComposerAction] {
        beginEditingFocusedWord() ?? []
    }

    private func alternativeForEditing(at wordIndex: Int) -> WordAlternative? {
        let words = TextSegmenter.wordTokens(from: displayedClause)
        guard wordIndex < words.count else { return nil }
        let surface = words[wordIndex]
        return WordAlternative(
            wordIndex: wordIndex,
            baseWord: VNIEngine.stripDiacritics(surface).lowercased(),
            selected: surface,
            candidates: [surface]
        )
    }

    /// Renders the popup for the inline retype: the hint plus the focused word's range in the preview text.
    private func editPresentation(for alternative: WordAlternative, showsImmediately: Bool) -> ComposerAction? {
        guard config.showCandidateHUD, let wordIndex = editWordIndex else { return nil }
        let previewText = markedText
        let range = utf16Range(ofWordAt: wordIndex, in: previewText)
            ?? NSRange(location: (previewText as NSString).length, length: 0)
        let shown = editBuffer.isEmpty ? alternative.selected : editBuffer
        return .showCandidates(CandidatePresentation(
            alternative: WordAlternative(
                wordIndex: wordIndex,
                baseWord: alternative.baseWord,
                selected: shown,
                candidates: []
            ),
            focusedRange: range,
            geminiChanges: [],
            showsImmediately: showsImmediately,
            isExpanded: false,
            editHint: editHintText(buffer: editBuffer)
        ))
    }

    private func editHintText(buffer: String) -> String {
        if buffer.isEmpty {
            return "✏️ Gõ lại từ · ↩ xác nhận · Esc huỷ"
        }
        return "✏️ Sửa từ: \(buffer) · ↩ xác nhận · Esc huỷ"
    }

    /// Handles every key while `⌥E` is active. Runs before all other shortcuts so the sub-state is hermetic.
    private func handleEditKey(_ key: ComposerKey) -> ComposerResult {
        guard let wordIndex = editWordIndex else { return ComposerResult(handled: false) }
        let keyCode = key.keyCode
        let flags = key.modifiers

        // Escape (with or without Option) cancels and restores the clause exactly.
        if keyCode == 53 {
            return finishEditing(confirm: false)
        }

        // Backspace deletes from the edit buffer; on an empty buffer it cancels the edit.
        if keyCode == 51 {
            if editBuffer.isEmpty {
                return finishEditing(confirm: false)
            }
            editBuffer.removeLast()
            return ComposerResult(handled: true, actions: editRefreshActions(wordIndex: wordIndex))
        }

        // Return / Space confirm the typed word.
        if keyCode == 36 || keyCode == 76 || keyCode == 49 {
            return finishEditing(confirm: true)
        }

        // Any other modified shortcut (⌘/⌃, arrows) cancels the edit and is handled normally afterwards.
        if flags.contains(.command) || flags.contains(.control)
            || [123, 124, 125, 126, 115, 116, 117, 119, 121].contains(keyCode) {
            let cancelled = finishEditing(confirm: false)
            return ComposerResult(handled: cancelled.handled, actions: cancelled.actions)
        }

        // Letters and VNI digits feed the edit buffer through the VNI engine (`ba6n5` -> `bận`).
        guard let chars = key.characters, !chars.isEmpty else {
            return ComposerResult(handled: true, actions: [])
        }
        for ch in chars {
            if ch.isLetter || ch.isNumber {
                let res = coordinator.vniEngine.processKey(currentWord: editBuffer, key: ch)
                editBuffer = res.newWord
            } else if ch == "'" || ch == "-" || ch == "_" {
                editBuffer.append(ch)
            } else {
                // Other punctuation/symbols cancel: they are almost always meant for the app, not the word.
                return finishEditing(confirm: false)
            }
        }
        return ComposerResult(handled: true, actions: editRefreshActions(wordIndex: wordIndex))
    }

    private func editRefreshActions(wordIndex: Int) -> [ComposerAction] {
        let alternative = alternativeForEditing(at: wordIndex)
            ?? WordAlternative(wordIndex: wordIndex, baseWord: "", selected: editBuffer, candidates: [])
        var actions: [ComposerAction] = [.setMarked(markedText)]
        if let shown = editPresentation(for: alternative, showsImmediately: true) {
            actions.append(shown)
        }
        return actions
    }

    private func finishEditing(confirm: Bool) -> ComposerResult {
        guard let wordIndex = editWordIndex else { return ComposerResult(handled: false) }

        let buffer = editBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        let wasEmpty = buffer.isEmpty
        let originDisplayed = editOriginDisplayed

        // Leave the sub-state either way, so no branch can keep it alive by accident.
        editWordIndex = nil
        editBuffer = ""
        editOriginDisplayed = ""

        guard confirm, !wasEmpty else {
            return ComposerResult(handled: true, actions: cancelEditActions(restoring: originDisplayed))
        }

        // Keep the word count stable: a buffer that splits into several words (or carries punctuation that
        // `TextSegmenter` folds into a different token, e.g. `ban-xyz`) is rejected.
        let bufferWords = TextSegmenter.wordTokens(from: buffer)
        let isSinglePlainWord = buffer.allSatisfy { $0.isLetter || $0.isNumber || $0 == "'" }
        guard bufferWords.count == 1, isSinglePlainWord else {
            // Re-enter the edit so the user can fix it instead of silently dropping the word.
            editWordIndex = wordIndex
            editBuffer = buffer
            editOriginDisplayed = originDisplayed
            var actions: [ComposerAction] = [.setMarked(replacingWord(at: wordIndex, with: buffer, in: originDisplayed))]
            if let shown = editPresentation(
                for: alternativeForEditing(at: wordIndex)
                    ?? WordAlternative(wordIndex: wordIndex, baseWord: "", selected: buffer, candidates: []),
                showsImmediately: true
            ) {
                actions.append(shown)
            }
            return ComposerResult(handled: true, actions: actions)
        }

        let newSurface = bufferWords[0]
        let newBase = VNIEngine.stripDiacritics(newSurface).lowercased()

        displayedClause = replacingWord(at: wordIndex, with: newSurface, in: displayedClause)
        rawClause = replacingWord(at: wordIndex, with: newBase, in: rawClause)
        lockedWords[wordIndex] = newSurface
        clauseVersion &+= 1
        geminiRefinedVersion = 0
        manualConvertedVersion = 0
        pendingGeminiChanges = []
        synthesizedFocusAlternative = nil
        focusedWordIndex = wordIndex
        expandedState = nil

        // Teach the store with the neighbouring *displayed* words, exactly like a candidate pick.
        let words = TextSegmenter.wordTokens(from: displayedClause)
        let prev1 = wordIndex >= 1 && wordIndex - 1 < words.count ? words[wordIndex - 1].lowercased() : nil
        let prev2 = wordIndex >= 2 && wordIndex - 2 < words.count ? words[wordIndex - 2].lowercased() : nil
        let next1 = wordIndex + 1 < words.count ? words[wordIndex + 1].lowercased() : nil
        coordinator.store.recordUserCorrection(
            baseWord: newBase,
            chosenSurface: newSurface,
            prev1: prev1,
            prev2: prev2,
            next1: next1
        )

        var actions: [ComposerAction] = [.cancelRefinement, .setMarked(displayedClause)]
        actions.append(.hideCandidates)
        return ComposerResult(handled: true, actions: actions)
    }

    private func cancelEditActions(restoring origin: String) -> [ComposerAction] {
        displayedClause = origin
        return [.setMarked(displayedClause), .hideCandidates]
    }

    // MARK: - Gemini Changes

    /// Word-by-word diff between what was displayed before a refinement and the merged result.
    private static func diffWords(previous: String, new: String) -> [GeminiChange] {
        let previousWords = TextSegmenter.wordTokens(from: previous)
        let newWords = TextSegmenter.wordTokens(from: new)
        guard !previousWords.isEmpty, previousWords.count == newWords.count else { return [] }
        return (0..<previousWords.count).compactMap { index in
            guard previousWords[index] != newWords[index] else { return nil }
            return GeminiChange(wordIndex: index, from: previousWords[index], to: newWords[index])
        }
    }

    private func alternativeForChangedWord(at index: Int, in text: String, result: ConversionResult) -> WordAlternative {
        if let existing = result.alternatives.first(where: { $0.wordIndex == index }) {
            return existing
        }
        let tokens = TextSegmenter.wordTokens(from: text)
        let newSurface = index < tokens.count ? tokens[index] : ""
        let previous = pendingGeminiChanges.first { $0.wordIndex == index }?.from ?? newSurface
        var candidates = [newSurface]
        if !previous.isEmpty, previous.lowercased() != newSurface.lowercased() {
            candidates.append(previous)
        }
        if candidates.isEmpty { candidates = [newSurface] }
        return WordAlternative(
            wordIndex: index,
            baseWord: VNIEngine.stripDiacritics(previous).lowercased(),
            selected: newSurface,
            candidates: candidates
        )
    }

    /// `⌥Esc` / popup "Hoàn tác" while Gemini changes are pending: restore only the changed words, lock them,
    /// teach the store, and keep the clause composing.
    private func revertGeminiChanges() -> [ComposerAction] {
        guard !pendingGeminiChanges.isEmpty else { return [] }
        let changes = pendingGeminiChanges.sorted { $0.wordIndex < $1.wordIndex }

        // Restore every changed word first, then learn against the final surrounding surfaces.
        for change in changes {
            displayedClause = replacingWord(at: change.wordIndex, with: change.from, in: displayedClause)
            lockedWords[change.wordIndex] = change.from
        }
        let words = TextSegmenter.wordTokens(from: displayedClause)

        for change in changes {
            let base = VNIEngine.stripDiacritics(change.from).lowercased()
            let newBase = VNIEngine.stripDiacritics(change.to).lowercased()
            guard !base.isEmpty, base == newBase else { continue }
            let prev1 = change.wordIndex >= 1 && change.wordIndex - 1 < words.count
                ? words[change.wordIndex - 1].lowercased()
                : nil
            let prev2 = change.wordIndex >= 2 && change.wordIndex - 2 < words.count
                ? words[change.wordIndex - 2].lowercased()
                : nil
            let next1 = change.wordIndex + 1 < words.count ? words[change.wordIndex + 1].lowercased() : nil
            coordinator.store.recordUserCorrection(
                baseWord: base,
                chosenSurface: change.from,
                prev1: prev1,
                prev2: prev2,
                next1: next1
            )
        }

        pendingGeminiChanges = []
        focusedWordIndex = nil
        synthesizedFocusAlternative = nil
        expandedState = nil
        clauseVersion &+= 1
        return [.cancelRefinement, .hideCandidates, .setMarked(displayedClause)]
    }

    private func replacingWord(at wordIndex: Int, with surface: String, in text: String) -> String {
        var result = ""
        for segment in TextSegmenter.segment(text) {
            if segment.isWord && segment.wordIndex == wordIndex {
                result.append(surface)
            } else {
                result.append(segment.raw)
            }
        }
        return result
    }

    /// UTF-16 range of a word in the marked text, punctuation-aware via `TextSegmenter`.
    private func utf16Range(ofWordAt wordIndex: Int, in text: String) -> NSRange? {
        var location = 0
        for segment in TextSegmenter.segment(text) {
            if segment.isWord && segment.wordIndex == wordIndex {
                return NSRange(location: location, length: segment.raw.utf16.count)
            }
            location += segment.raw.utf16.count
        }
        return nil
    }

    // MARK: - Word Utilities

    /// While the user keeps typing into a word that was explicitly locked (inline VNI / candidate pick), the lock
    /// must follow the visible word; otherwise the newly typed letters are discarded by `applyLockedWords` at commit.
    private func syncLockOfWordStillBeingTyped() {
        guard !lockedWords.isEmpty else { return }
        let wordIdx = wordCount(in: rawClause) - 1
        guard wordIdx >= 0, lockedWords[wordIdx] != nil else { return }
        guard let tail = TextSegmenter.wordTokens(from: displayedClause).last else { return }
        lockedWords[wordIdx] = tail
    }

    private func splitLastWord(_ text: String) -> (prefix: String, tail: String) {
        if let lastSpace = text.lastIndex(where: { $0.isWhitespace }) {
            let afterSpace = text.index(after: lastSpace)
            return (String(text[..<afterSpace]), String(text[afterSpace...]))
        }
        return ("", text)
    }

    /// Word count with the same tokenizer the engine uses for `WordAlternative.wordIndex`, so every lock,
    /// focus and Gemini-change index refers to the same word (e.g. `e-mail` is two words everywhere).
    private func wordCount(in text: String) -> Int {
        TextSegmenter.wordTokens(from: text).count
    }

    private func applyLockedWords(to text: String) -> String {
        guard !lockedWords.isEmpty else { return text }
        var result = ""
        for segment in TextSegmenter.segment(text) {
            if segment.isWord, let locked = lockedWords[segment.wordIndex] {
                result.append(locked)
            } else {
                result.append(segment.raw)
            }
        }
        return result
    }

    private func optionDigitIndex(keyCode: UInt16) -> Int? {
        switch keyCode {
        case 18: return 0 // 1
        case 19: return 1 // 2
        case 20: return 2 // 3
        case 21: return 3 // 4
        case 23: return 4 // 5
        default: return nil
        }
    }
}
