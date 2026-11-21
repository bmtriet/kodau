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
    case showCandidates(WordAlternative)
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

    private let maxMarkedWords = 12
    private let maxManualMarkedWords = 28

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
        vniWordBuffer.isEmpty ? displayedClause : vniWordBuffer
    }

    // MARK: - Main Entry Point

    /// Processes one key-down event and returns whether the adapter must consume it.
    public func handleKey(_ key: ComposerKey) -> ComposerResult {
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

            // Option + Escape: revert composing clause to raw ASCII (English) & teach store
            if keyCode == 53 && !rawClause.isEmpty {
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
            let localRes = runLocalConversionPreservingLocks(raw: rawClause)
            displayedClause = localRes.convertedText
            lastResult = localRes
            var actions: [ComposerAction] = [.hideCandidates, .setMarked(displayedClause)]
            if let candidate = candidateAction(for: localRes) {
                actions.append(candidate)
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

        rawClause.removeLast()
        if !displayedClause.isEmpty {
            displayedClause.removeLast()
        }

        // Drop locks beyond the current word count
        let currentWords = rawClause.split(whereSeparator: { $0.isWhitespace }).count
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
        guard let alt = lastResult?.alternatives.last, index >= 0, index < alt.candidates.count else {
            return nil
        }
        let chosen = alt.candidates[index]
        let updated = coordinator.applyUserCorrection(
            rawClause: rawClause,
            currentConverted: displayedClause,
            wordIndex: alt.wordIndex,
            chosenWord: chosen
        )
        lockedWords[alt.wordIndex] = chosen
        displayedClause = updated
        clauseVersion &+= 1
        return [.cancelRefinement, .hideCandidates, .setMarked(displayedClause)]
    }

    /// Applies a candidate clicked in the floating quick-fix popup. Same effect as `⌥1..5` for that surface,
    /// including teaching the LearningStore, and hides the popup.
    public func selectCandidate(_ surface: String) -> [ComposerAction] {
        guard let alt = lastResult?.alternatives.last else { return [] }
        let target = surface.lowercased()
        guard let index = alt.candidates.firstIndex(where: { $0.lowercased() == target }) else { return [] }
        return applyAlternativeCandidate(index: index) ?? []
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
        let versionSnapshot = clauseVersion

        let localRes = runLocalConversionPreservingLocks(raw: rawClause)
        displayedClause = localRes.convertedText
        lastResult = localRes
        manualConvertedVersion = versionSnapshot
        actions.append(.hideCandidates)
        actions.append(.setMarked(displayedClause))
        if let candidate = candidateAction(for: localRes) {
            actions.append(candidate)
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
        let merged = applyLockedWords(to: result.convertedText) + trailingSpaces
        displayedClause = merged
        lastResult = result
        geminiRefinedVersion = request.version

        var actions: [ComposerAction] = [.hideCandidates, .setMarked(merged)]
        if let candidate = candidateAction(for: result) {
            actions.append(candidate)
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

    private func candidateAction(for result: ConversionResult) -> ComposerAction? {
        guard config.showCandidateHUD, let alt = result.alternatives.last, alt.candidates.count > 1 else {
            return nil
        }
        return .showCandidates(alt)
    }

    // MARK: - Word Utilities

    /// While the user keeps typing into a word that was explicitly locked (inline VNI / candidate pick), the lock
    /// must follow the visible word; otherwise the newly typed letters are discarded by `applyLockedWords` at commit.
    private func syncLockOfWordStillBeingTyped() {
        guard !lockedWords.isEmpty else { return }
        let wordIdx = wordCount(in: rawClause) - 1
        guard wordIdx >= 0, lockedWords[wordIdx] != nil else { return }
        let (_, tail) = splitLastWord(displayedClause)
        lockedWords[wordIdx] = tail
    }

    private func splitLastWord(_ text: String) -> (prefix: String, tail: String) {
        if let lastSpace = text.lastIndex(where: { $0.isWhitespace }) {
            let afterSpace = text.index(after: lastSpace)
            return (String(text[..<afterSpace]), String(text[afterSpace...]))
        }
        return ("", text)
    }

    private func wordCount(in text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    private func applyLockedWords(to text: String) -> String {
        guard !lockedWords.isEmpty else { return text }
        var result = ""
        var wordIdx = 0
        var idx = text.startIndex

        while idx < text.endIndex {
            if text[idx].isWhitespace {
                result.append(text[idx])
                idx = text.index(after: idx)
            } else {
                let start = idx
                while idx < text.endIndex && !text[idx].isWhitespace {
                    idx = text.index(after: idx)
                }
                let token = String(text[start..<idx])
                if let locked = lockedWords[wordIdx] {
                    result.append(locked)
                } else {
                    result.append(token)
                }
                wordIdx += 1
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
