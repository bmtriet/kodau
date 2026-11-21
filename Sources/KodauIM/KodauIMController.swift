import Cocoa
import Carbon
import InputMethodKit
import KodauCore

/// Native macOS `IMKInputController` for **Kodau** — Smart Vietnamese (no diacritics) + English + VNI.
///
/// Key guarantees:
/// - Registered natively in System Settings -> Keyboard -> Input Sources (`~/Library/Input Methods/KodauIM.app`).
/// - Uses native `setMarkedText` (zero synthetic Backspaces while composing, zero clipboard interference).
/// - macOS automatically switches away from `KodauIM` to built-in ASCII/ABC inside password fields
///   (`NSSecureTextField`, web `<input type="password">`, `sudo`, etc.) — passwords are 100% untouched.
/// - Shares the exact same `LearningStore` SQLite brain and `AppConfig` (`gemini-3.5-flash-lite`) with `Kodau.app`.
@objc(KodauIMController)
final class KodauIMController: IMKInputController {

    private var runtime: KodauIMRuntime { KodauIMRuntime.shared }

    // MARK: - Composing State

    /// Exact raw ASCII text typed in the current composing clause (Smart mode).
    private var rawClause: String = ""
    /// Current rendered text shown via `setMarkedText`.
    private var displayedClause: String = ""
    /// Current word buffer when in dedicated VNI mode.
    private var vniWordBuffer: String = ""
    /// Word indices explicitly set by user (via inline VNI override or Option+1..5 candidate pick).
    private var lockedWords: [Int: String] = [:]
    /// Most recent conversion result (for Option+1..5 alternatives & confidence).
    private var lastResult: ConversionResult?
    /// Trailing few committed words for cross-clause context.
    private var recentCommittedContext: String = ""
    /// Monotonic version guard against stale async Gemini responses.
    private var clauseVersion: UInt64 = 0
    /// In-flight debounced Gemini refinement task.
    private var geminiTask: Task<Void, Never>?
    /// Track whether Gemini already refined the current clauseVersion.
    private var geminiRefinedVersion: UInt64 = 0
    /// Track whether the user manually triggered conversion (Option+Space) on the current clauseVersion.
    private var manualConvertedVersion: UInt64 = 0
    /// Weak reference to the latest active client for async marked-text updates.
    private weak var activeClientObject: AnyObject?

    private let maxMarkedWords = 12
    private let maxManualMarkedWords = 28

    // MARK: - Edit-Correction Learning State

    /// Tracks a user going back into already-committed text to fix a word (Backspace / typing over a selection).
    private struct EditSession {
        /// Word at the edit point before the user started changing it (nil when the app does not expose its text).
        var original: WordAtCursor?
        /// UTF-16 document location of the edit point (updated after each commit).
        var lastLocation: Int
        /// Whether the user typed anything (vs. pure deletion) during the session.
        var typed: Bool = false
        let startedAt: Date = Date()
    }

    private var editSession: EditSession?
    private var editIdleTimer: Timer?
    private var editIdleRetries = 0
    /// Words Kodau committed recently (newest last) — fallback for apps that cannot report text before an edit.
    private var recentCommittedWords: [String] = []
    private static let editIdleSeconds: TimeInterval = 1.5
    private static let editSessionMaxAge: TimeInterval = 45
    private static let navigationKeyCodes: Set<UInt16> = [123, 124, 125, 126, 115, 116, 117, 119, 121]

    // MARK: - Lifecycle

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        runtime.reloadConfigIfNeeded()
        activeClientObject = sender as AnyObject?
    }

    override func deactivateServer(_ sender: Any!) {
        commitCurrentComposition(client: sender)
        finalizeEditSession(client: sender)
        geminiTask?.cancel()
        geminiTask = nil
        super.deactivateServer(sender)
    }

    override func commitComposition(_ sender: Any!) {
        commitCurrentComposition(client: sender)
        // Usually triggered by a mouse click / app switch: the edited word is final now.
        finalizeEditSession(client: sender)
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        return Int(NSEvent.EventTypeMask.keyDown.rawValue)
    }

    override func selectionRange() -> NSRange {
        let len = currentMarkedString().utf16.count
        return NSRange(location: len, length: 0)
    }

    override func replacementRange() -> NSRange {
        return NSRange(location: NSNotFound, length: 0)
    }

    // MARK: - Main Event Handler

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event = event, event.type == .keyDown else {
            return false
        }

        runtime.reloadConfigIfNeeded()
        activeClientObject = sender as AnyObject?

        if handleCorrectionToastHotkey(event) {
            return true
        }

        beginEditTracking(event: event, client: sender)
        let handled = handleKey(event, client: sender)
        endEditTracking(event: event, client: sender)
        return handled
    }

    private func handleKey(_ event: NSEvent, client sender: Any!) -> Bool {

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let keyCode = event.keyCode
        let config = runtime.config

        // Global mode cycle shortcut inside KodauIM: Ctrl + Shift + Space
        if keyCode == 49 && flags.contains(.control) && flags.contains(.shift) && !flags.contains(.command) {
            commitCurrentComposition(client: sender)
            runtime.updateConfig { cfg in
                cfg.typingMode = cfg.typingMode.next
            }
            return true
        }

        // Option + Space / Option + 1...5 / Option + Escape
        if flags.contains(.option) && !flags.contains(.command) && !flags.contains(.control) {
            // Option + Space: force conversion of the current VNI word or Smart clause.
            // Holding the key must not re-run the conversion (and its Gemini call) on every auto-repeat.
            if keyCode == 49 && !flags.contains(.shift) && config.typingMode != .english {
                guard !event.isARepeat else { return true }
                if config.typingMode == .vni {
                    if triggerManualVNIConversion(client: sender) { return true }
                } else if !rawClause.isEmpty {
                    triggerManualConversion(client: sender)
                    return true
                } else if config.triggerMode == .manual {
                    return true
                }
            }
            // Only consume Option+1..5 when a candidate was actually applied; otherwise fall through so the
            // composition is committed before the app receives the Option-character (e.g. "¡").
            if let digitIndex = optionDigitIndex(keyCode: keyCode), !rawClause.isEmpty,
               applyAlternativeCandidate(index: digitIndex, client: sender) {
                return true
            }
            // Option + Escape: revert composing clause to raw ASCII (English) & teach store
            if keyCode == 53 && !rawClause.isEmpty {
                revertAndCommitRawASCII(client: sender)
                return true
            }
        }

        // Pass through Command / Control / Function shortcuts after committing any pending buffer
        if flags.contains(.command) || flags.contains(.control) {
            commitCurrentComposition(client: sender)
            return false
        }

        // English / raw pass-through mode
        if config.typingMode == .english {
            commitCurrentComposition(client: sender)
            return false
        }

        // Special keys: Backspace, Escape, Return, Tab, Arrow/Navigation keys
        switch keyCode {
        case 51: // Delete / Backspace
            return handleBackspace(client: sender, mode: config.typingMode)

        case 53: // Escape -> revert to raw ASCII if composing
            if !rawClause.isEmpty {
                revertAndCommitRawASCII(client: sender)
                return true
            }
            if !vniWordBuffer.isEmpty {
                let raw = VNIEngine.stripDiacritics(vniWordBuffer)
                commitLiteral(raw, client: sender)
                resetBuffers()
                return true
            }
            return false

        case 36, 76: // Return / Enter
            if hasActiveBuffer {
                commitCurrentComposition(client: sender)
            }
            // Return false so the target app receives Return (sends chat message / inserts newline)
            return false

        case 48: // Tab
            if hasActiveBuffer {
                commitCurrentComposition(client: sender)
            }
            return false

        case 123, 124, 125, 126, 115, 116, 117, 119, 121:
            // Arrows, Home, End, PageUp, PageDown, Forward Delete
            if hasActiveBuffer {
                commitCurrentComposition(client: sender)
            }
            return false

        default:
            break
        }

        // Extract printable character
        guard let chars = event.characters, chars.count == 1, let ch = chars.first else {
            if hasActiveBuffer {
                commitCurrentComposition(client: sender)
            }
            return false
        }

        // Ignore control / non-printable characters
        if let scalar = ch.unicodeScalars.first, scalar.value < 0x20 || scalar.value == 0x7F {
            if hasActiveBuffer {
                commitCurrentComposition(client: sender)
            }
            return false
        }

        switch config.typingMode {
        case .vni:
            return handleVNICharacter(ch, client: sender)
        case .smart:
            return handleSmartCharacter(ch, client: sender)
        case .english:
            return false
        }
    }

    // MARK: - Dedicated VNI Mode

    private func handleVNICharacter(_ ch: Character, client sender: Any!) -> Bool {
        if ch.isLetter || ch.isNumber {
            let result = runtime.coordinator.vniEngine.processKey(currentWord: vniWordBuffer, key: ch)
            vniWordBuffer = result.newWord
            setMarked(vniWordBuffer, client: sender)
            return true
        }

        // Delimiter (space or punctuation): commit VNI word + delimiter
        if !vniWordBuffer.isEmpty {
            let finalized = vniWordBuffer
            commitLiteral(finalized + String(ch), client: sender)
            runtime.coordinator.learnFromVNIWord(finalized, precedingContext: recentCommittedContext)
            appendToRecentContext(finalized)
            resetBuffers()
            return true
        }

        return false
    }

    /// `Option + Space` in VNI mode. VNI inserts each character straight into the app, so only the word still
    /// being composed can be rewritten safely. Words already committed on this line are left untouched.
    /// Returns `false` when there is nothing to restore so the key falls through to the normal VNI path.
    private func triggerManualVNIConversion(client sender: Any!) -> Bool {
        geminiTask?.cancel()
        geminiTask = nil

        let wordOnScreen = vniWordBuffer
        let asciiWord = VNIEngine.stripDiacritics(wordOnScreen)
        guard !wordOnScreen.isEmpty, !asciiWord.isEmpty,
              !VNIEngine.containsVietnameseDiacritics(wordOnScreen) else {
            return false
        }

        clauseVersion &+= 1
        let versionSnapshot = clauseVersion

        let localRes = runtime.coordinator.convertSync(
            asciiWord,
            precedingContext: recentCommittedContext,
            forceSmartEngine: true
        )
        let restoredWord = localRes.convertedText
        guard restoredWord != wordOnScreen else { return false }

        vniWordBuffer = restoredWord
        lastResult = localRes
        manualConvertedVersion = versionSnapshot
        setMarked(restoredWord, client: sender)

        let config = runtime.config
        if config.hasAPIKey && config.brainStrategy != .offlineOnly {
            let contextSnapshot = recentCommittedContext
            geminiTask = Task { [weak self] in
                let result = await KodauIMRuntime.shared.coordinator.convertSmart(
                    asciiWord,
                    precedingContext: contextSnapshot,
                    forceSmartEngine: true
                )
                KodauIMRuntime.shared.notifyStatsChanged()
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    guard let self, self.clauseVersion == versionSnapshot else { return }
                    self.vniWordBuffer = result.convertedText
                    self.lastResult = result
                    self.geminiRefinedVersion = versionSnapshot
                    if let clientObj = self.activeClientObject {
                        self.setMarked(result.convertedText, client: clientObj)
                    }
                }
            }
        } else {
            // The restored word is learned when the VNI word is committed, so only telemetry here.
            runtime.store.recordConversionEvent(source: localRes.source)
            runtime.notifyStatsChanged()
        }

        return true
    }

    // MARK: - Smart Mode (Auto Vietnamese Không Dấu + English + Inline VNI)

    private func handleSmartCharacter(_ ch: Character, client sender: Any!) -> Bool {
        let config = runtime.config

        // 1. Space
        if ch == " " {
            if rawClause.isEmpty {
                return false
            }

            // Manual Trigger Mode: keep raw text untouched in marked buffer until Option+Space
            if config.triggerMode == .manual {
                rawClause.append(" ")
                displayedClause.append(" ")
                clauseVersion &+= 1
                setMarked(displayedClause, client: sender)

                let words = rawClause.split(whereSeparator: { $0.isWhitespace })
                if words.count >= maxManualMarkedWords {
                    commitCurrentComposition(client: sender)
                }
                return true
            }

            // Avoid double space issues; if already ends with space, commit and pass space through
            if rawClause.hasSuffix(" ") {
                commitCurrentComposition(client: sender)
                return false
            }

            rawClause.append(" ")
            clauseVersion &+= 1
            let localRes = runLocalConversionPreservingLocks(raw: rawClause)
            displayedClause = localRes.convertedText
            lastResult = localRes
            setMarked(displayedClause, client: sender)

            // If clause is getting long, commit completed prefix so marked text stays sleek
            let words = rawClause.split(whereSeparator: { $0.isWhitespace })
            if words.count >= maxMarkedWords {
                commitCurrentComposition(client: sender)
                return true
            }

            // Schedule debounced Gemini refinement when appropriate
            scheduleGeminiIfNeeded(
                rawSnapshot: rawClause,
                localResult: localRes,
                versionSnapshot: clauseVersion,
                client: sender
            )
            return true
        }

        // 2. Sentence-ending or clause punctuation
        if Self.commitPunctuation.contains(ch) {
            if rawClause.isEmpty {
                return false
            }

            // Manual Trigger Mode:
            // - If user ALREADY pressed Option+Space on this clause, commit the converted text + punctuation.
            // - Otherwise keep raw text + punctuation untouched in marked buffer so Option+Space can convert the whole sentence!
            if config.triggerMode == .manual {
                let alreadyConverted = (manualConvertedVersion == clauseVersion || geminiRefinedVersion == clauseVersion)
                if alreadyConverted {
                    geminiTask?.cancel()
                    geminiTask = nil
                    if geminiRefinedVersion != clauseVersion, let res = lastResult {
                        runtime.store.recordConversionEvent(source: res.source)
                    }
                    let finalText = displayedClause
                    commitLiteral(finalText + String(ch), client: sender)
                    appendToRecentContext(finalText)
                    resetBuffers()
                    return true
                }
                rawClause.append(ch)
                displayedClause.append(ch)
                clauseVersion &+= 1
                setMarked(displayedClause, client: sender)
                return true
            }

            geminiTask?.cancel()
            geminiTask = nil

            let wasGeminiRefined = (geminiRefinedVersion == clauseVersion)
            let finalLocal = runLocalConversionPreservingLocks(raw: rawClause)
            let finalText = (wasGeminiRefined && !displayedClause.isEmpty)
                ? displayedClause
                : finalLocal.convertedText

            let rawSnapshot = rawClause
            let ctxSnapshot = recentCommittedContext

            commitLiteral(finalText + String(ch), client: sender)
            runtime.store.recordConversionEvent(source: finalLocal.source)
            appendToRecentContext(finalText)
            resetBuffers()

            // Silent background distillation if Gemini hasn't seen this ambiguous clause yet
            if shouldAskGemini(localResult: finalLocal, config: config) && !wasGeminiRefined {
                let coordinator = runtime.coordinator
                Task.detached(priority: .utility) {
                    _ = await coordinator.convertSmart(rawSnapshot, precedingContext: ctxSnapshot)
                    KodauIMRuntime.shared.notifyStatsChanged()
                }
            }
            return true
        }

        // 3. Inline VNI digit override inside Smart Mode (e.g., `tie6ng1`, `ban5`, `tu72`, `dau61`, `d9uoc75`)
        if ch.isNumber && config.inlineVNIOverrideEnabled && !rawClause.isEmpty && !rawClause.hasSuffix(" ") {
            let (rawPrefix, _) = splitLastWord(rawClause)
            let (dispPrefix, dispTail) = splitLastWord(displayedClause)
            let candidateDisp = dispTail + String(ch)

            if !dispTail.isEmpty && runtime.coordinator.vniEngine.looksLikeInlineVNI(candidateDisp) {
                let vniRes = runtime.coordinator.vniEngine.processKey(currentWord: dispTail, key: ch)
                if vniRes.didTransform {
                    geminiTask?.cancel()
                    geminiTask = nil
                    clauseVersion &+= 1

                    let wordIdx = wordCount(in: rawPrefix)
                    let baseAscii = VNIEngine.stripDiacritics(vniRes.newWord).lowercased()
                    rawClause = rawPrefix + baseAscii
                    displayedClause = dispPrefix + vniRes.newWord
                    lockedWords[wordIdx] = vniRes.newWord
                    setMarked(displayedClause, client: sender)

                    // Immediately teach LearningStore with userVerified = true!
                    let prevWords = dispPrefix.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                    runtime.store.recordUserCorrection(
                        baseWord: baseAscii,
                        chosenSurface: vniRes.newWord,
                        prev1: prevWords.last?.lowercased(),
                        prev2: prevWords.count >= 2 ? prevWords[prevWords.count - 2].lowercased() : nil
                    )
                    return true
                }
            }
        }

        // 4. Normal character (letters, digits, apostrophe, hyphen, slash, @, etc.)
        if ch.isLetter || ch.isNumber || ch == "'" || ch == "-" || ch == "_" {
            geminiTask?.cancel()
            geminiTask = nil
            clauseVersion &+= 1

            rawClause.append(ch)
            displayedClause.append(ch)
            setMarked(displayedClause, client: sender)
            return true
        }

        // 5. Any other symbol (e.g., quotes, brackets, operators): commit current clause and let symbol pass through
        if hasActiveBuffer {
            commitCurrentComposition(client: sender)
        }
        return false
    }

    // MARK: - Backspace & Candidate Picking

    private func handleBackspace(client sender: Any!, mode: TypingMode) -> Bool {
        if mode == .vni {
            guard !vniWordBuffer.isEmpty else { return false }
            vniWordBuffer.removeLast()
            if vniWordBuffer.isEmpty {
                clearMarked(client: sender)
            } else {
                setMarked(vniWordBuffer, client: sender)
            }
            return true
        }

        guard !rawClause.isEmpty else { return false }

        geminiTask?.cancel()
        geminiTask = nil
        clauseVersion &+= 1

        rawClause.removeLast()
        if !displayedClause.isEmpty {
            displayedClause.removeLast()
        }

        // Drop locks beyond the current word count
        let currentWords = rawClause.split(whereSeparator: { $0.isWhitespace }).count
        lockedWords = lockedWords.filter { $0.key < currentWords }

        if rawClause.isEmpty {
            resetBuffers()
            clearMarked(client: sender)
        } else {
            // Re-sync displayed clause cleanly if lengths diverged
            if displayedClause.count != rawClause.count {
                if runtime.config.triggerMode == .manual {
                    displayedClause = applyLockedWords(to: rawClause)
                } else {
                    let res = runLocalConversionPreservingLocks(raw: rawClause)
                    displayedClause = res.convertedText
                    lastResult = res
                }
            }
            setMarked(displayedClause, client: sender)
        }
        return true
    }

    private func applyAlternativeCandidate(index: Int, client sender: Any!) -> Bool {
        guard let alt = lastResult?.alternatives.last, index >= 0, index < alt.candidates.count else {
            return false
        }
        let chosen = alt.candidates[index]
        let updated = runtime.coordinator.applyUserCorrection(
            rawClause: rawClause,
            currentConverted: displayedClause,
            wordIndex: alt.wordIndex,
            chosenWord: chosen
        )
        lockedWords[alt.wordIndex] = chosen
        displayedClause = updated
        clauseVersion &+= 1
        setMarked(displayedClause, client: sender)
        return true
    }

    private func revertAndCommitRawASCII(client sender: Any!) {
        geminiTask?.cancel()
        geminiTask = nil
        let raw = rawClause
        commitLiteral(raw, client: sender)
        // Teach LearningStore that the user explicitly wanted these words kept as raw ASCII / English
        let tokens = raw.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        for (idx, token) in tokens.enumerated() {
            let base = VNIEngine.stripDiacritics(token).lowercased()
            guard !base.isEmpty else { continue }
            let p1 = idx > 0 ? tokens[idx - 1].lowercased() : nil
            let p2 = idx > 1 ? tokens[idx - 2].lowercased() : nil
            runtime.store.recordUserCorrection(
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
        resetBuffers()
    }

    // MARK: - Local + Async Gemini Refinement

    /// Triggered by Option+Space: immediately converts the current `rawClause` (Local + 0ms Gemini if configured)
    /// and updates `setMarkedText` in place.
    private func triggerManualConversion(client sender: Any!) {
        geminiTask?.cancel()
        geminiTask = nil

        let trimmed = rawClause.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        clauseVersion &+= 1
        let versionSnapshot = clauseVersion

        let localRes = runLocalConversionPreservingLocks(raw: rawClause)
        displayedClause = localRes.convertedText
        lastResult = localRes
        manualConvertedVersion = versionSnapshot
        setMarked(displayedClause, client: sender)

        let config = runtime.config
        if config.hasAPIKey && config.brainStrategy != .offlineOnly {
            scheduleGeminiIfNeeded(
                rawSnapshot: rawClause,
                localResult: localRes,
                versionSnapshot: versionSnapshot,
                client: sender,
                delayMsOverride: 0,
                forceRun: true
            )
        }
        // Offline conversions are recorded once at commit time (see `commitCurrentComposition`),
        // so we do not record here to avoid double-counting stats.
    }

    private func runLocalConversionPreservingLocks(raw: String) -> ConversionResult {
        let baseResult = runtime.coordinator.convertSync(raw, precedingContext: recentCommittedContext)
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
        client sender: Any!,
        delayMsOverride: Int? = nil,
        forceRun: Bool = false
    ) {
        let config = runtime.config
        if !forceRun {
            guard shouldAskGemini(localResult: localResult, config: config) else { return }
        } else {
            guard config.hasAPIKey && config.brainStrategy != .offlineOnly else { return }
        }

        geminiTask?.cancel()
        // Per-sentence timing waits for a real typing pause mid-sentence; punctuation / Return commit locally and
        // distill with Gemini once in the background, so each sentence costs about one call.
        let defaultDelayMs = config.geminiTiming == .perSentence
            ? max(500, config.sentencePauseMilliseconds)
            : max(120, config.debounceMilliseconds)
        let effectiveDelayMs = delayMsOverride ?? defaultDelayMs
        let delayNs = UInt64(max(0, effectiveDelayMs)) * 1_000_000
        let contextSnapshot = recentCommittedContext
        let coordinator = runtime.coordinator

        geminiTask = Task { [weak self] in
            if delayNs > 0 {
                do {
                    try await Task.sleep(nanoseconds: delayNs)
                } catch {
                    return
                }
            }

            let trimmedRaw = rawSnapshot.trimmingCharacters(in: .whitespaces)
            guard !trimmedRaw.isEmpty else { return }

            let result = await coordinator.convertSmart(trimmedRaw, precedingContext: contextSnapshot)
            KodauIMRuntime.shared.notifyStatsChanged()
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self else { return }
                guard self.clauseVersion == versionSnapshot else { return }
                guard let clientObj = self.activeClientObject else { return }

                let trailingSpacesCount = rawSnapshot.reversed().prefix(while: { $0 == " " }).count
                let trailingSpaces = String(repeating: " ", count: trailingSpacesCount)
                let merged = self.applyLockedWords(to: result.convertedText) + trailingSpaces
                self.displayedClause = merged
                self.lastResult = result
                self.geminiRefinedVersion = versionSnapshot
                self.setMarked(merged, client: clientObj)
            }
        }
    }

    // MARK: - Commit & Marked Text Helpers

    private var hasActiveBuffer: Bool {
        !rawClause.isEmpty || !vniWordBuffer.isEmpty
    }

    private func currentMarkedString() -> String {
        if !vniWordBuffer.isEmpty { return vniWordBuffer }
        return displayedClause
    }

    private func commitCurrentComposition(client sender: Any!) {
        geminiTask?.cancel()
        geminiTask = nil

        if !vniWordBuffer.isEmpty {
            let word = vniWordBuffer
            commitLiteral(word, client: sender)
            runtime.coordinator.learnFromVNIWord(word, precedingContext: recentCommittedContext)
            appendToRecentContext(word)
            resetBuffers()
            return
        }

        if !rawClause.isEmpty {
            let config = runtime.config
            let rawSnapshot = rawClause
            let ctxSnapshot = recentCommittedContext
            let wasGeminiRefined = (geminiRefinedVersion == clauseVersion)
            let wasManuallyConverted = (manualConvertedVersion == clauseVersion)

            // In Manual Trigger Mode: commit raw text untouched UNLESS user already pressed Option+Space
            if config.triggerMode == .manual {
                let textToCommit = !displayedClause.isEmpty ? displayedClause : rawSnapshot
                if wasManuallyConverted && !wasGeminiRefined, let res = lastResult {
                    runtime.store.recordConversionEvent(source: res.source)
                }
                commitLiteral(textToCommit, client: sender)
                appendToRecentContext(textToCommit)
                resetBuffers()
                return
            }

            // In Automatic Mode: synchronously convert before commit (so Return inserts newline AFTER converted line 1!)
            let textToCommit: String
            var localResForDistill: ConversionResult? = nil
            if wasGeminiRefined && !displayedClause.isEmpty {
                textToCommit = displayedClause
            } else {
                let res = runLocalConversionPreservingLocks(raw: rawSnapshot)
                localResForDistill = res
                textToCommit = res.convertedText
                runtime.store.recordConversionEvent(source: res.source)
            }
            commitLiteral(textToCommit, client: sender)
            appendToRecentContext(textToCommit)
            resetBuffers()

            // Silently distill & learn with Gemini in background if needed and not yet refined
            if !wasGeminiRefined,
               let localRes = localResForDistill,
               shouldAskGemini(localResult: localRes, config: config) {
                let coordinator = runtime.coordinator
                Task.detached(priority: .utility) {
                    _ = await coordinator.convertSmart(rawSnapshot, precedingContext: ctxSnapshot)
                    KodauIMRuntime.shared.notifyStatsChanged()
                }
            }
        }
    }

    private func setMarked(_ text: String, client sender: Any!) {
        guard let textInput = sender as? IMKTextInput else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: NSColor.controlAccentColor.withAlphaComponent(0.75)
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let selRange = NSRange(location: text.utf16.count, length: 0)
        let repRange = NSRange(location: NSNotFound, length: 0)
        textInput.setMarkedText(attrStr, selectionRange: selRange, replacementRange: repRange)
    }

    private func clearMarked(client sender: Any!) {
        guard let textInput = sender as? IMKTextInput else { return }
        textInput.setMarkedText(
            NSAttributedString(string: ""),
            selectionRange: NSRange(location: 0, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    private func commitLiteral(_ text: String, client sender: Any!) {
        guard let textInput = sender as? IMKTextInput else { return }
        // Where the committed text will end in the document (computed before inserting, since a mouse click
        // may already have moved the selection by the time `commitComposition` is called).
        let marked = textInput.markedRange()
        textInput.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))

        rememberCommittedWords(text)
        if editSession != nil {
            if marked.location != NSNotFound {
                editSession?.lastLocation = marked.location + text.utf16.count
            } else {
                let sel = textInput.selectedRange()
                if sel.location != NSNotFound { editSession?.lastLocation = sel.location }
            }
        }
    }

    private func resetBuffers() {
        rawClause = ""
        displayedClause = ""
        vniWordBuffer = ""
        lockedWords = [:]
        lastResult = nil
        clauseVersion &+= 1
        geminiRefinedVersion = 0
        manualConvertedVersion = 0
        runtime.notifyStatsChanged()
    }

    private func appendToRecentContext(_ text: String) {
        let combined = (recentCommittedContext + " " + text)
            .split(whereSeparator: { $0.isWhitespace })
            .suffix(4)
            .joined(separator: " ")
        recentCommittedContext = combined
    }

    // MARK: - Word Utilities

    private static let commitPunctuation: Set<Character> = [
        ".", ",", "!", "?", ";", ":"
    ]

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

    // MARK: - Native macOS Input Sources Menu Bar Dropdown

    override func menu() -> NSMenu! {
        runtime.reloadConfigIfNeeded()
        let config = runtime.config
        let stats = runtime.coordinator.currentStats()
        let menu = NSMenu(title: "Kodau")

        let header = NSMenuItem(
            title: "Kodau — \(config.typingMode.displayName)",
            action: nil,
            keyEquivalent: ""
        )
        header.isEnabled = false
        menu.addItem(header)

        let statsPct = Int((stats.offlineHitRate * 100).rounded())
        let statsItem = NSMenuItem(
            title: "Đã học \(stats.uniqueWordsLearned) từ · Offline \(statsPct)% · \(config.geminiModel)",
            action: nil,
            keyEquivalent: ""
        )
        statsItem.isEnabled = false
        menu.addItem(statsItem)
        menu.addItem(.separator())

        // Typing mode items
        for mode in TypingMode.allCases {
            let item = NSMenuItem(
                title: mode.displayName,
                action: #selector(selectTypingMode(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = mode.rawValue
            item.state = (config.typingMode == mode) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // Conversion trigger mode items (Automatic vs Manual Option+Space)
        let triggerHeader = NSMenuItem(
            title: "Chế độ thêm dấu: Tự động / Thủ công (⌥Space, cả Smart và VNI)",
            action: nil,
            keyEquivalent: ""
        )
        triggerHeader.isEnabled = false
        menu.addItem(triggerHeader)

        for triggerMode in ConversionTriggerMode.allCases {
            let item = NSMenuItem(
                title: triggerMode.displayName,
                action: #selector(selectTriggerMode(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = triggerMode.rawValue
            item.state = (config.triggerMode == triggerMode) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // Brain strategy items
        for strategy in BrainStrategy.allCases {
            let item = NSMenuItem(
                title: strategy.displayName,
                action: #selector(selectBrainStrategy(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = strategy.rawValue
            item.state = (config.brainStrategy == strategy) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let openDashboard = NSMenuItem(
            title: "Mở Bảng điều khiển Kodau & Gemini API Key...",
            action: #selector(openDashboardAction(_:)),
            keyEquivalent: ""
        )
        openDashboard.target = self
        menu.addItem(openDashboard)

        return menu
    }

    @objc private func selectTypingMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = TypingMode(rawValue: raw) else { return }
        runtime.updateConfig { $0.typingMode = mode }
    }

    @objc private func selectTriggerMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let triggerMode = ConversionTriggerMode(rawValue: raw) else { return }
        runtime.updateConfig { $0.triggerMode = triggerMode }
    }

    @objc private func selectBrainStrategy(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let strategy = BrainStrategy(rawValue: raw) else { return }
        runtime.updateConfig { $0.brainStrategy = strategy }
    }

    @objc private func openDashboardAction(_ sender: NSMenuItem) {
        runtime.openDashboardApp()
    }
}

// MARK: - Learning From Post-Commit Edits (bottom-center confirm toast)

extension KodauIMController {

    /// `⌥↩` confirms the pending "learn this word?" toast; `⌥Esc` dismisses it (only when nothing is composing).
    fileprivate func handleCorrectionToastHotkey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.option), !flags.contains(.command), !flags.contains(.control), !flags.contains(.shift) else {
            return false
        }
        return MainActor.assumeIsolated {
            let toast = CorrectionToastController.shared
            guard toast.isVisible else { return false }
            switch event.keyCode {
            case 36, 76:
                return toast.confirm()
            case 53 where !hasActiveBuffer:
                toast.dismiss()
                return true
            default:
                return false
            }
        }
    }

    fileprivate func beginEditTracking(event: NSEvent, client sender: Any!) {
        let config = runtime.config
        guard config.learnFromEditsEnabled, config.typingMode != .english else {
            discardEditSession()
            return
        }
        if let session = editSession, Date().timeIntervalSince(session.startedAt) > Self.editSessionMaxAge {
            discardEditSession()
        }
        guard editSession == nil, !hasActiveBuffer, let client = sender as? IMKTextInput else { return }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.command), !flags.contains(.control) else { return }

        let sel = client.selectedRange()
        guard sel.location != NSNotFound else { return }

        if event.keyCode == 51 {
            // Backspace into committed text: snapshot the word being fixed BEFORE the app deletes anything.
            let anchor = sel.length > 0 ? sel.location + sel.length : sel.location
            editSession = EditSession(original: readWord(client: client, around: anchor), lastLocation: sel.location)
        } else if sel.length > 0, isTypingCharacter(event) {
            // Typing over a selected word replaces it.
            var actual = NSRange(location: NSNotFound, length: 0)
            let selected = client.string(from: sel, actualRange: &actual)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let original = (!selected.isEmpty && !selected.contains(where: { $0.isWhitespace }))
                ? WordAtCursor(word: selected)
                : nil
            editSession = EditSession(original: original, lastLocation: sel.location)
        }
    }

    fileprivate func endEditTracking(event: NSEvent, client sender: Any!) {
        guard editSession != nil else { return }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let keyCode = event.keyCode
        let isCommandShortcut = flags.contains(.command) || flags.contains(.control)
        let isNavigation = Self.navigationKeyCodes.contains(keyCode)
        let isBoundary = isCommandShortcut || isNavigation
            || [36, 76, 48, 53].contains(keyCode)
            || (event.characters.map { $0 == " " || $0.count == 1 && Self.commitPunctuation.contains($0.first!) } ?? false)

        if isTypingCharacter(event) && !isCommandShortcut {
            editSession?.typed = true
        }

        guard editSession?.typed == true else {
            // Pure deletion followed by moving away: nothing to learn.
            if isNavigation || isCommandShortcut || [36, 76, 48].contains(keyCode) {
                discardEditSession()
            }
            return
        }

        if isBoundary && !hasActiveBuffer {
            finalizeEditSession(client: sender)
        } else {
            scheduleEditIdleCheck()
        }
    }

    private func scheduleEditIdleCheck() {
        editIdleTimer?.invalidate()
        editIdleRetries = 0
        editIdleTimer = Timer.scheduledTimer(withTimeInterval: Self.editIdleSeconds, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if self.editSession == nil {
                timer.invalidate()
                return
            }
            // Still composing (marked text): wait for the user to finish, but not forever.
            if self.hasActiveBuffer {
                self.editIdleRetries += 1
                if self.editIdleRetries > 20 { timer.invalidate() }
                return
            }
            timer.invalidate()
            self.finalizeEditSession(client: self.activeClientObject)
        }
    }

    fileprivate func finalizeEditSession(client sender: Any!) {
        guard let session = editSession else { return }
        discardEditSession()
        guard session.typed, runtime.config.learnFromEditsEnabled else { return }
        guard let client = (sender as? IMKTextInput) ?? (activeClientObject as? IMKTextInput) else { return }

        let edited = readWord(client: client, around: session.lastLocation)
        guard let candidate = EditCorrectionDetector.candidate(
            original: session.original,
            edited: edited,
            recentCommittedWords: recentCommittedWords
        ) else { return }

        var caretRect = NSRect.zero
        _ = client.attributes(forCharacterIndex: max(0, session.lastLocation - 1), lineHeightRectangle: &caretRect)
        MainActor.assumeIsolated {
            CorrectionToastController.shared.show(candidate, near: caretRect)
        }
    }

    private func discardEditSession() {
        editSession = nil
        editIdleTimer?.invalidate()
        editIdleTimer = nil
    }

    /// Reads a small window of document text around `location` and returns the word touching it.
    private func readWord(client: IMKTextInput, around location: Int) -> WordAtCursor? {
        let start = max(0, location - 48)
        var length = (location - start) + 48
        let docLength = client.length()
        if docLength > 0 && docLength != NSNotFound {
            length = max(0, min(length, docLength - start))
        }
        guard length > 0 else { return nil }

        var actual = NSRange(location: NSNotFound, length: 0)
        guard let text = client.string(from: NSRange(location: start, length: length), actualRange: &actual),
              !text.isEmpty else {
            return nil
        }
        let windowStart = actual.location == NSNotFound ? start : actual.location
        return EditCorrectionDetector.wordAtCursor(in: text, cursorUTF16Offset: location - windowStart)
    }

    private func rememberCommittedWords(_ text: String) {
        let words = text.split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard !words.isEmpty else { return }
        recentCommittedWords.append(contentsOf: words)
        if recentCommittedWords.count > 200 {
            recentCommittedWords.removeFirst(recentCommittedWords.count - 200)
        }
    }

    private func isTypingCharacter(_ event: NSEvent) -> Bool {
        guard let chars = event.characters, chars.count == 1, let ch = chars.first else { return false }
        return ch.isLetter || ch.isNumber
    }
}
