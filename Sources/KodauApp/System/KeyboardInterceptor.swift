import Foundation
import AppKit
import Carbon
import ApplicationServices
import KodauCore

/// Global macOS keyboard hook built on `CGEventTap`.
///
/// Design invariants:
/// 1. Every synthetic event posted by Kodau carries `eventSourceUserData == 0x4B4F4441` ("KODA")
///    so our own backspaces and Unicode insertions never re-enter the hook.
/// 2. Password fields & macOS Secure Event Input are checked first on every keystroke; when active,
///    buffers are wiped immediately and events pass through 100% untouched.
/// 3. Timeout / user-input tap disable notifications re-enable the tap immediately so macOS never freezes.
/// 4. Never touches the system clipboard (`NSPasteboard`).
public final class KeyboardInterceptor: @unchecked Sendable {

    /// Magic tag ("KODA") stamped on all synthetic CGEvents emitted by Kodau.
    private static let kodauEventTag: Int64 = 0x4B4F4441

    /// Private-state source for every synthetic event. Events created with a `nil` source inherit the modifiers the
    /// user is physically holding: right after `⌥Space`, Option is still down, so each injected Backspace became
    /// `⌥⌫` (delete a whole word) and wiped the start of the line (e.g. the leading "M" of "Mô tả...").
    private static let syntheticEventSource = CGEventSource(stateID: .privateState)

    /// Modifier bits a synthetic Return must carry over from the user's original keystroke (e.g. Shift+Return).
    private static let modifierMask: CGEventFlags = [.maskShift, .maskAlternate, .maskCommand, .maskControl]

    /// Maximum clause buffer length before rotating older words into `precedingContext`.
    private static let maxClauseBufferLength = 120

    /// Key codes used on macOS keyboards.
    private enum KeyCode {
        static let returnKey: Int64 = 36
        static let enterKey: Int64 = 76
        static let tab: Int64 = 48
        static let space: Int64 = 49
        static let delete: Int64 = 51
        static let escape: Int64 = 53
        static let forwardDelete: Int64 = 117
        static let home: Int64 = 115
        static let end: Int64 = 119
        static let pageUp: Int64 = 116
        static let pageDown: Int64 = 121
        static let leftArrow: Int64 = 123
        static let rightArrow: Int64 = 124
        static let downArrow: Int64 = 125
        static let upArrow: Int64 = 126

        // Number row 1..5
        static let digit1: Int64 = 18
        static let digit2: Int64 = 19
        static let digit3: Int64 = 20
        static let digit4: Int64 = 21
        static let digit5: Int64 = 23
    }

    private static let boundaryPunctuation: Set<Character> = [
        ".", ",", "!", "?", ";", ":"
    ]

    private static let sentenceEndingPunctuation: Set<Character> = [
        ".", "!", "?"
    ]

    private static let vniHardBoundaryPunctuation: Set<Character> = [
        ".", ",", "!", "?", ";", ":", "(", ")", "[", "]", "{", "}", "\"", "'", "/", "\\", "-", "—", "\t"
    ]

    // MARK: - Dependencies & State

    private let coordinator: SmartCoordinator
    private var config: AppConfig

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var mouseMonitor: Any?
    private var workspaceObserver: NSObjectProtocol?
    private var securePollTimer: Timer?

    public private(set) var isRunning: Bool = false
    private var lastSecureState: Bool = false
    private var lastSecureReason: String?

    // VNI mode state
    private var vniWordBuffer: String = ""
    private var recentVNIContext: String = ""

    // Smart mode state
    private var rawClauseBuffer: String = ""
    private var displayedClauseBuffer: String = ""
    private var currentWordBuffer: String = ""
    private var currentWordWasInlineVNI: Bool = false
    private var precedingContext: String = ""
    private var bufferVersion: UInt64 = 0
    private var pendingSmartTask: Task<Void, Never>?

    // Last conversion metadata for Option+1..5 candidate swaps and Option+Esc undo
    private var activeAlternative: WordAlternative?
    private var lastRawClause: String = ""
    private var lastConvertedClause: String = ""
    private var lastTrailingSuffix: String = ""
    private var lastConversionVersion: UInt64 = 0

    // MARK: - Callbacks (always invoked on main thread)

    public var onModeChanged: ((TypingMode) -> Void)?
    public var onSecureInputStateChanged: ((Bool, String?) -> Void)?
    public var onLastConversionChanged: ((ConversionResult) -> Void)?
    public var onActiveCandidatesChanged: ((WordAlternative?) -> Void)?
    public var onStatsDidChange: (() -> Void)?

    // MARK: - Lifecycle

    public init(coordinator: SmartCoordinator, config: AppConfig) {
        self.coordinator = coordinator
        self.config = config
    }

    deinit {
        stop()
    }

    public func updateConfig(_ newConfig: AppConfig) {
        let modeChanged = config.typingMode != newConfig.typingMode
        let triggerModeChanged = config.triggerMode != newConfig.triggerMode
        self.config = newConfig
        if modeChanged {
            resetAllBuffers(clearContext: true)
        } else if triggerModeChanged && newConfig.triggerMode == .manual {
            pendingSmartTask?.cancel()
            pendingSmartTask = nil
        }
    }

    @discardableResult
    public func start() -> Bool {
        if isRunning { return true }
        guard SecureInputMonitor.isAccessibilityTrusted(prompt: false) else {
            return false
        }

        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else {
                return Unmanaged.passUnretained(event)
            }
            let interceptor = Unmanaged<KeyboardInterceptor>.fromOpaque(refcon).takeUnretainedValue()
            return interceptor.handleEvent(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: userInfo
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        self.isRunning = true

        installContextResetMonitors()
        startSecureInputPolling()

        return true
    }

    public func stop() {
        pendingSmartTask?.cancel()
        pendingSmartTask = nil

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        securePollTimer?.invalidate()

        eventTap = nil
        runLoopSource = nil
        mouseMonitor = nil
        workspaceObserver = nil
        securePollTimer = nil
        isRunning = false
        resetAllBuffers(clearContext: true)
    }

    // MARK: - Monitors

    private func installContextResetMonitors() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.resetAllBuffers(clearContext: false)
            }
        }

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.resetAllBuffers(clearContext: true)
            self?.pollSecureInputState()
        }
    }

    private func startSecureInputPolling() {
        securePollTimer?.invalidate()
        securePollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollSecureInputState()
        }
        pollSecureInputState()
    }

    private func pollSecureInputState() {
        let state = SecureInputMonitor.isPasswordFieldOrSecureInputActive(
            excludedBundleIDs: config.excludedBundleIDs
        )
        updateSecureState(isSecure: state.isSecure, reason: state.reason)
    }

    private func updateSecureState(isSecure: Bool, reason: String?) {
        if isSecure {
            if !rawClauseBuffer.isEmpty || !vniWordBuffer.isEmpty || activeAlternative != nil {
                resetAllBuffers(clearContext: true)
            }
        }
        if isSecure != lastSecureState || reason != lastSecureReason {
            lastSecureState = isSecure
            lastSecureReason = reason
            onSecureInputStateChanged?(isSecure, reason)
        }
    }

    // MARK: - Core CGEventTap Callback

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 1. Auto-recover if macOS disabled the tap due to timeout or user input
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        // 2. Never re-process our own synthetic events
        if event.getIntegerValueField(.eventSourceUserData) == Self.kodauEventTag {
            return Unmanaged.passUnretained(event)
        }

        // 2.5. If the native macOS Input Method (KodauIM) is currently active, let KodauIM handle everything!
        if SecureInputMonitor.isNativeKodauIMActive() {
            if !rawClauseBuffer.isEmpty || !vniWordBuffer.isEmpty {
                resetAllBuffers(clearContext: false)
            }
            return Unmanaged.passUnretained(event)
        }

        // 3. Password / Secure Input safety guarantee (ALWAYS runs first)
        let secureCheck = SecureInputMonitor.isPasswordFieldOrSecureInputActive(
            excludedBundleIDs: config.excludedBundleIDs
        )
        updateSecureState(isSecure: secureCheck.isSecure, reason: secureCheck.reason)
        if secureCheck.isSecure {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        // 4. Global hotkeys
        if let hotkeyHandled = handleGlobalHotkeys(keyCode: keyCode, flags: flags, isRepeat: isRepeat) {
            return hotkeyHandled ? nil : Unmanaged.passUnretained(event)
        }

        // 5. English mode passes everything through untouched
        if config.typingMode == .english {
            return Unmanaged.passUnretained(event)
        }

        // 6. Command / Control shortcuts reset buffers and pass through
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            resetAllBuffers(clearContext: false)
            return Unmanaged.passUnretained(event)
        }

        // 7. Navigation / cursor-moving keys reset buffers and pass through
        if isNavigationOrResetKey(keyCode: keyCode) {
            resetAllBuffers(clearContext: keyCode == KeyCode.escape)
            return Unmanaged.passUnretained(event)
        }

        // 8. Backspace updates internal buffers and passes through
        if keyCode == KeyCode.delete {
            handleBackspace()
            return Unmanaged.passUnretained(event)
        }

        // 9. Extract Unicode string from event
        let unicodeStr = extractUnicodeString(from: event)

        switch config.typingMode {
        case .vni:
            return handleVNIModeKey(keyCode: keyCode, unicodeStr: unicodeStr, event: event)
        case .smart:
            return handleSmartModeKey(keyCode: keyCode, unicodeStr: unicodeStr, event: event)
        case .english:
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: - Global Hotkeys

    /// Returns `true` if the hotkey was handled and the event should be consumed,
    /// `nil` if the event is not a Kodau hotkey.
    private func handleGlobalHotkeys(keyCode: Int64, flags: CGEventFlags, isRepeat: Bool) -> Bool? {
        let hasCmd = flags.contains(.maskCommand)
        let hasCtrl = flags.contains(.maskControl)
        let hasShift = flags.contains(.maskShift)
        let hasOpt = flags.contains(.maskAlternate)

        // Ctrl + Shift + Space -> Cycle TypingMode (Smart -> VNI -> English)
        if keyCode == KeyCode.space && hasCtrl && hasShift && !hasCmd && !hasOpt {
            guard !isRepeat else { return true }
            let nextMode = config.typingMode.next
            config.typingMode = nextMode
            resetAllBuffers(clearContext: true)
            onModeChanged?(nextMode)
            return true
        }

        // Option + ... hotkeys (no Cmd/Ctrl/Shift)
        if hasOpt && !hasCmd && !hasCtrl && !hasShift {
            // Option + Space -> force conversion of the current clause in Smart AND VNI mode.
            // Holding the key must not re-run the conversion (and its Gemini call) on every auto-repeat.
            if keyCode == KeyCode.space && config.typingMode != .english {
                guard !isRepeat else { return true }
                if triggerManualConversion() {
                    return true
                }
                if config.typingMode == .vni {
                    // Nothing to restore: pass the key on so the VNI path treats it as a word boundary.
                    return nil
                }
                // Manual trigger mode consumes the key so the non-breaking space is never typed.
                if config.triggerMode == .manual {
                    return true
                }
            }

            // Option + 1...5 -> Quick candidate selection when Candidate HUD has alternatives
            if let index = optionDigitIndex(for: keyCode),
               let alt = activeAlternative,
               index < alt.candidates.count {
                let chosen = alt.candidates[index]
                applyCandidateSelection(chosen)
                return true
            }

            // Option + Escape -> Undo last conversion and learn raw/ASCII term
            if keyCode == KeyCode.escape && !lastRawClause.isEmpty && lastRawClause != lastConvertedClause {
                if undoLastConversion() {
                    return true
                }
            }
        }

        return nil
    }

    private func optionDigitIndex(for keyCode: Int64) -> Int? {
        switch keyCode {
        case KeyCode.digit1: return 0
        case KeyCode.digit2: return 1
        case KeyCode.digit3: return 2
        case KeyCode.digit4: return 3
        case KeyCode.digit5: return 4
        default: return nil
        }
    }

    // MARK: - VNI Mode

    private func handleVNIModeKey(
        keyCode: Int64,
        unicodeStr: String,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        let isReturn = (keyCode == KeyCode.returnKey || keyCode == KeyCode.enterKey)
        let isSpace = (keyCode == KeyCode.space)

        if isReturn || isSpace {
            finalizeVNIWord(clearContext: isReturn)
            return Unmanaged.passUnretained(event)
        }

        guard let ch = unicodeStr.first, unicodeStr.count == 1 else {
            finalizeVNIWord(clearContext: false)
            return Unmanaged.passUnretained(event)
        }

        if Self.vniHardBoundaryPunctuation.contains(ch) || ch.isWhitespace {
            finalizeVNIWord(clearContext: Self.sentenceEndingPunctuation.contains(ch))
            return Unmanaged.passUnretained(event)
        }

        guard ch.isLetter || ch.isNumber else {
            finalizeVNIWord(clearContext: false)
            return Unmanaged.passUnretained(event)
        }

        let result = coordinator.vniEngine.processKey(currentWord: vniWordBuffer, key: ch)
        vniWordBuffer = result.newWord

        if result.didTransform {
            injectBackspaces(result.backspacesNeeded)
            injectUnicodeText(result.textToInsert)
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    private func finalizeVNIWord(clearContext: Bool) {
        if !vniWordBuffer.isEmpty && config.learnFromVNIMode {
            let word = vniWordBuffer
            coordinator.learnFromVNIWord(word, precedingContext: recentVNIContext)
            appendToContext(&recentVNIContext, text: word)
            onStatsDidChange?()
        }
        vniWordBuffer = ""
        if clearContext {
            recentVNIContext = ""
        }
    }

    // MARK: - Smart Mode

    private func handleSmartModeKey(
        keyCode: Int64,
        unicodeStr: String,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        let isReturn = (keyCode == KeyCode.returnKey || keyCode == KeyCode.enterKey)
        let isSpace = (keyCode == KeyCode.space)

        // Word / Clause boundary
        if isReturn || isSpace {
            return handleSmartBoundary(
                keyCode: keyCode,
                boundaryChar: isSpace ? " " : nil,
                isReturn: isReturn,
                isSentenceEnd: isReturn,
                originalEvent: event
            )
        }

        guard let ch = unicodeStr.first, unicodeStr.count == 1 else {
            resetAllBuffers(clearContext: false)
            return Unmanaged.passUnretained(event)
        }

        if Self.boundaryPunctuation.contains(ch) {
            return handleSmartBoundary(
                keyCode: keyCode,
                boundaryChar: String(ch),
                isReturn: false,
                isSentenceEnd: Self.sentenceEndingPunctuation.contains(ch),
                originalEvent: event
            )
        }

        // Inline VNI Override: e.g. typing `ban5`, `tu72`, `dau61`, or `tie6ng1` directly inside Smart Mode
        if config.inlineVNIOverrideEnabled,
           !currentWordBuffer.isEmpty,
           (ch.isNumber || (currentWordWasInlineVNI && ch.isLetter)) {
            let shouldTryVNI: Bool
            if ch.isNumber {
                let candidateToken = currentWordBuffer + String(ch)
                shouldTryVNI = coordinator.vniEngine.looksLikeInlineVNI(candidateToken)
            } else {
                shouldTryVNI = true
            }

            if shouldTryVNI {
                let vniRes = coordinator.vniEngine.processKey(currentWord: currentWordBuffer, key: ch)
                if vniRes.didTransform {
                    pendingSmartTask?.cancel()
                    bufferVersion &+= 1
                    clearActiveCandidateHUD()

                    injectBackspaces(vniRes.backspacesNeeded)
                    injectUnicodeText(vniRes.textToInsert)

                    // Update displayed and raw buffers to stay aligned on the locked VNI word
                    displayedClauseBuffer = applyingEdit(
                        to: displayedClauseBuffer,
                        backspaces: vniRes.backspacesNeeded,
                        insertion: vniRes.textToInsert
                    )
                    if rawClauseBuffer.hasSuffix(currentWordBuffer) {
                        rawClauseBuffer.removeLast(currentWordBuffer.count)
                        rawClauseBuffer.append(vniRes.newWord)
                    } else {
                        rawClauseBuffer = applyingEdit(
                            to: rawClauseBuffer,
                            backspaces: vniRes.backspacesNeeded,
                            insertion: vniRes.textToInsert
                        )
                    }
                    currentWordBuffer = vniRes.newWord
                    currentWordWasInlineVNI = true
                    return nil
                }
            }
        }

        // Other non-word punctuation (quotes, parens, slashes, etc.)
        if !ch.isLetter && !ch.isNumber && ch != "'" && ch != "-" && ch != "_" {
            finalizeInlineVNIIfNeeded()
            currentWordBuffer = ""
            pendingSmartTask?.cancel()
            bufferVersion &+= 1
            rawClauseBuffer.append(ch)
            displayedClauseBuffer.append(ch)
            trimClauseBufferIfNeeded()
            return Unmanaged.passUnretained(event)
        }

        // Normal typing character: ZERO-latency pass-through!
        pendingSmartTask?.cancel()
        bufferVersion &+= 1
        clearActiveCandidateHUD()

        rawClauseBuffer.append(ch)
        displayedClauseBuffer.append(ch)
        currentWordBuffer.append(ch)
        trimClauseBufferIfNeeded()

        return Unmanaged.passUnretained(event)
    }

    private func handleSmartBoundary(
        keyCode: Int64,
        boundaryChar: String?,
        isReturn: Bool,
        isSentenceEnd: Bool,
        originalEvent: CGEvent
    ) -> Unmanaged<CGEvent>? {
        pendingSmartTask?.cancel()
        finalizeInlineVNIIfNeeded()
        currentWordBuffer = ""

        // Manual Trigger Mode: do NOT auto-convert and do NOT auto-call Gemini on Space/Punctuation/Return.
        // Accumulate the full line/clause in buffers so Option+Space can convert it on demand!
        if config.triggerMode == .manual {
            bufferVersion &+= 1
            if isReturn {
                appendToContext(&precedingContext, text: displayedClauseBuffer)
                rawClauseBuffer = ""
                displayedClauseBuffer = ""
                currentWordBuffer = ""
                return Unmanaged.passUnretained(originalEvent)
            }
            if let boundaryChar {
                rawClauseBuffer.append(boundaryChar)
                displayedClauseBuffer.append(boundaryChar)
                trimClauseBufferIfNeeded()
            }
            return Unmanaged.passUnretained(originalEvent)
        }

        let trimmedRaw = rawClauseBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRaw.isEmpty else {
            if isReturn || isSentenceEnd {
                resetAllBuffers(clearContext: false)
            } else if let boundaryChar {
                rawClauseBuffer.append(boundaryChar)
                displayedClauseBuffer.append(boundaryChar)
            }
            return Unmanaged.passUnretained(originalEvent)
        }

        let clauseRaw = rawClauseBuffer
        let clauseDisplayed = displayedClauseBuffer
        let contextSnapshot = precedingContext

        // 1. Fast synchronous local pass (<1ms)
        let syncResult = coordinator.convertSync(clauseRaw, precedingContext: contextSnapshot)

        let needsCloudRefinement: Bool = {
            guard config.hasAPIKey else { return false }
            if syncResult.source == .localEnglish && syncResult.confidence >= 0.85 {
                return false
            }
            switch config.brainStrategy {
            case .offlineOnly:
                return false
            case .cloudFirst:
                return true
            case .hybrid:
                return syncResult.confidence < config.localConfidenceThreshold
            }
        }()

        // Automatic mode:
        // - On Return: ALWAYS apply syncResult immediately before newline whenever it differs and isn't English
        //   (fixes Bug #2 where line 1 stayed unaccented on Return!).
        // - On Space / punctuation: apply syncResult immediately for instant Vietnamese feedback when offline,
        //   without API key, or local confidence >= 0.55; Gemini still refines in-place if needsCloudRefinement is true.
        // Per-sentence Gemini timing: the local result is always shown immediately; Gemini refines the whole
        // sentence once at `. ! ?` / Return / a longer pause, instead of after every short pause.
        let perSentence = config.geminiTiming == .perSentence
        let shouldApplySync: Bool = {
            guard syncResult.convertedText != clauseDisplayed && syncResult.source != .localEnglish else {
                return false
            }
            if isReturn {
                return true
            }
            return perSentence
                || config.brainStrategy == .offlineOnly
                || !config.hasAPIKey
                || syncResult.confidence >= 0.55
        }()

        var consumedOriginalEvent = false

        if shouldApplySync {
            // Atomic minimal diff replacement + boundary character/return key
            let applied = applyMinimalDiffReplacement(
                currentOnScreen: clauseDisplayed,
                targetText: syncResult.convertedText,
                trailingText: boundaryChar ?? "",
                postReturnAfter: isReturn,
                returnFlags: originalEvent.flags.intersection(Self.modifierMask)
            )
            if applied {
                consumedOriginalEvent = true
                displayedClauseBuffer = syncResult.convertedText
                recordLastConversionState(
                    result: syncResult,
                    rawClause: clauseRaw,
                    convertedClause: syncResult.convertedText,
                    trailingSuffix: boundaryChar ?? ""
                )
            }
        }

        // Append trailing boundary character (for Space / Punctuation) to tracked buffers
        if let boundaryChar {
            rawClauseBuffer.append(boundaryChar)
            displayedClauseBuffer.append(boundaryChar)
        }

        bufferVersion &+= 1
        let postBoundaryVersion = bufferVersion

        // 2. If Return was pressed, commit context & reset — NEVER async-edit after Return (chat apps submit on Return!)
        //    If Gemini refinement was warranted, silently distill & learn in the background for next time.
        if isReturn {
            if needsCloudRefinement {
                let coordinatorRef = coordinator
                Task.detached(priority: .utility) { [weak self] in
                    _ = await coordinatorRef.convertSmart(clauseRaw, precedingContext: contextSnapshot)
                    guard let strongSelf = self else { return }
                    await MainActor.run {
                        strongSelf.onStatsDidChange?()
                    }
                }
            } else if shouldApplySync {
                coordinator.store.recordConversionEvent(source: syncResult.source)
                onStatsDidChange?()
            }

            appendToContext(&precedingContext, text: displayedClauseBuffer)
            rawClauseBuffer = ""
            displayedClauseBuffer = ""
            currentWordBuffer = ""
            return consumedOriginalEvent ? nil : Unmanaged.passUnretained(originalEvent)
        }

        // 3. Schedule debounced async Gemini refinement when appropriate
        if needsCloudRefinement {
            let delayMs: Int
            if isSentenceEnd {
                delayMs = min(config.debounceMilliseconds, 140)
            } else if perSentence {
                // Mid-sentence (Space / , ; :): only call when the user really stops typing.
                delayMs = max(500, config.sentencePauseMilliseconds)
            } else {
                delayMs = max(120, config.debounceMilliseconds)
            }
            let trailingSnapshot = boundaryChar ?? ""
            let rawSnapshot = clauseRaw
            let displayedClauseBeforeBoundary = displayedClauseBuffer.hasSuffix(trailingSnapshot)
                ? String(displayedClauseBuffer.dropLast(trailingSnapshot.count))
                : displayedClauseBuffer

            scheduleAsyncGeminiRefinement(
                rawClause: rawSnapshot,
                displayedClauseWithoutTrailing: displayedClauseBeforeBoundary,
                trailingSuffix: trailingSnapshot,
                precedingContext: contextSnapshot,
                expectedVersion: postBoundaryVersion,
                delayMs: delayMs,
                isSentenceEnd: isSentenceEnd
            )
        } else if isSentenceEnd {
            coordinator.store.recordConversionEvent(source: syncResult.source)
            appendToContext(&precedingContext, text: displayedClauseBuffer)
            rawClauseBuffer = ""
            displayedClauseBuffer = ""
            onStatsDidChange?()
        } else if shouldApplySync {
            onStatsDidChange?()
        }

        return consumedOriginalEvent ? nil : Unmanaged.passUnretained(originalEvent)
    }

    /// Routes `Option + Space` to the conversion path that matches the active typing mode.
    @discardableResult
    private func triggerManualConversion() -> Bool {
        switch config.typingMode {
        case .smart: return triggerManualSmartConversion()
        case .vni: return triggerManualVNIConversion()
        case .english: return false
        }
    }

    /// `Option + Space` in VNI mode. The VNI engine inserts characters straight into the app, so only the word
    /// currently being typed can be rewritten safely; earlier words of the line are already committed.
    /// Nothing happens when the word already carries diacritics — VNI restored it while typing.
    @discardableResult
    private func triggerManualVNIConversion() -> Bool {
        pendingSmartTask?.cancel()
        pendingSmartTask = nil

        let wordOnScreen = vniWordBuffer
        let asciiWord = VNIEngine.stripDiacritics(wordOnScreen)
        guard !wordOnScreen.isEmpty, !asciiWord.isEmpty,
              !VNIEngine.containsVietnameseDiacritics(wordOnScreen) else {
            return false
        }

        let contextSnapshot = recentVNIContext
        let syncResult = coordinator.convertSync(
            asciiWord,
            precedingContext: contextSnapshot,
            forceSmartEngine: true
        )
        let restoredWord = syncResult.convertedText
        guard restoredWord != wordOnScreen else { return false }

        injectBackspaces(wordOnScreen.count)
        usleep(1200)
        injectUnicodeText(restoredWord)
        vniWordBuffer = restoredWord
        bufferVersion &+= 1
        let expectedVersion = bufferVersion

        if config.hasAPIKey && config.brainStrategy != .offlineOnly {
            scheduleAsyncGeminiRefinement(
                rawClause: asciiWord,
                displayedClauseWithoutTrailing: restoredWord,
                trailingSuffix: "",
                precedingContext: contextSnapshot,
                expectedVersion: expectedVersion,
                delayMs: 0,
                isSentenceEnd: false,
                forceSmartEngine: true
            )
        } else {
            // The restored word is learned when `finalizeVNIWord` closes the word, so only telemetry here.
            coordinator.store.recordConversionEvent(source: syncResult.source)
            onStatsDidChange?()
        }

        onLastConversionChanged?(syncResult)
        return true
    }

    /// Manually triggers immediate conversion (Local + 0ms Gemini if configured) for the accumulated `rawClauseBuffer`.
    /// Works in both `.manual` and `.automatic` trigger modes via `Option + Space`.
    @discardableResult
    private func triggerManualSmartConversion() -> Bool {
        pendingSmartTask?.cancel()
        finalizeInlineVNIIfNeeded()
        currentWordBuffer = ""

        let trimmedRaw = rawClauseBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRaw.isEmpty else { return false }

        let clauseRaw = rawClauseBuffer
        let clauseDisplayed = displayedClauseBuffer
        let contextSnapshot = precedingContext

        // Preserve any trailing whitespace so user's cursor spacing stays natural
        let trailingSpacesCount = clauseRaw.reversed().prefix(while: { $0 == " " }).count
        let trailingSuffix = String(repeating: " ", count: trailingSpacesCount)
        let coreRaw = trailingSpacesCount > 0 ? String(clauseRaw.dropLast(trailingSpacesCount)) : clauseRaw

        // 1. Instant local conversion (<1ms) for immediate visual feedback if offline or confident
        let syncResult = coordinator.convertSync(coreRaw, precedingContext: contextSnapshot)
        let desiredSyncOnScreen = syncResult.convertedText + trailingSuffix
        let shouldApplySync = desiredSyncOnScreen != clauseDisplayed
            && syncResult.source != .localEnglish
            && (config.brainStrategy == .offlineOnly
                || !config.hasAPIKey
                || syncResult.confidence >= 0.55)

        if shouldApplySync {
            let applied = applyMinimalDiffReplacement(
                currentOnScreen: clauseDisplayed,
                targetText: desiredSyncOnScreen,
                trailingText: "",
                postReturnAfter: false
            )
            if applied {
                displayedClauseBuffer = desiredSyncOnScreen
                recordLastConversionState(
                    result: syncResult,
                    rawClause: coreRaw,
                    convertedClause: syncResult.convertedText,
                    trailingSuffix: trailingSuffix
                )
            }
        }

        bufferVersion &+= 1
        let expectedVersion = bufferVersion

        // 2. Immediately invoke SmartCoordinator (Local + Gemini) with 0ms debounce when API is enabled
        if config.hasAPIKey && config.brainStrategy != .offlineOnly {
            scheduleAsyncGeminiRefinement(
                rawClause: coreRaw,
                displayedClauseWithoutTrailing: syncResult.convertedText,
                trailingSuffix: trailingSuffix,
                precedingContext: contextSnapshot,
                expectedVersion: expectedVersion,
                delayMs: 0,
                isSentenceEnd: false
            )
        } else {
            coordinator.store.recordConversionEvent(source: syncResult.source)
            onStatsDidChange?()
        }

        return true
    }

    private func scheduleAsyncGeminiRefinement(
        rawClause: String,
        displayedClauseWithoutTrailing: String,
        trailingSuffix: String,
        precedingContext: String,
        expectedVersion: UInt64,
        delayMs: Int,
        isSentenceEnd: Bool,
        forceSmartEngine: Bool = false
    ) {
        pendingSmartTask?.cancel()
        pendingSmartTask = Task { [weak self] in
            if delayMs > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                } catch {
                    return
                }
            }
            guard let self, !Task.isCancelled else { return }

            let smartResult = await self.coordinator.convertSmart(
                rawClause,
                precedingContext: precedingContext,
                forceSmartEngine: forceSmartEngine
            )

            await MainActor.run {
                guard !Task.isCancelled else { return }

                // Check secure input again before emitting any synthetic events
                let secure = SecureInputMonitor.isPasswordFieldOrSecureInputActive(
                    excludedBundleIDs: self.config.excludedBundleIDs
                )
                if secure.isSecure {
                    self.updateSecureState(isSecure: true, reason: secure.reason)
                    return
                }

                // Always refresh stats since convertSmart may have learned from Gemini
                self.onStatsDidChange?()

                // Only edit on-screen text if the user has NOT typed anything since pausing
                guard self.bufferVersion == expectedVersion else {
                    return
                }

                // VNI mode tracks the word being typed in `vniWordBuffer`, not in the clause buffer.
                if forceSmartEngine {
                    let currentOnScreen = self.vniWordBuffer
                    let desiredOnScreen = smartResult.convertedText
                    if desiredOnScreen != currentOnScreen {
                        _ = self.applyMinimalDiffReplacement(
                            currentOnScreen: currentOnScreen,
                            targetText: desiredOnScreen,
                            trailingText: "",
                            postReturnAfter: false
                        )
                        self.vniWordBuffer = desiredOnScreen
                    }
                    self.onLastConversionChanged?(smartResult)
                    return
                }

                let desiredOnScreen = smartResult.convertedText + trailingSuffix
                if desiredOnScreen != self.displayedClauseBuffer {
                    _ = self.applyMinimalDiffReplacement(
                        currentOnScreen: self.displayedClauseBuffer,
                        targetText: desiredOnScreen,
                        trailingText: "",
                        postReturnAfter: false
                    )
                    self.displayedClauseBuffer = desiredOnScreen
                }

                self.recordLastConversionState(
                    result: smartResult,
                    rawClause: rawClause,
                    convertedClause: smartResult.convertedText,
                    trailingSuffix: trailingSuffix
                )

                if isSentenceEnd {
                    self.appendToContext(&self.precedingContext, text: self.displayedClauseBuffer)
                    self.rawClauseBuffer = ""
                    self.displayedClauseBuffer = ""
                }
            }
        }
    }

    // MARK: - Candidate Swap & Undo (Public for HUD + Hotkeys)

    /// Replaces the ambiguous word in the last converted clause with `chosenCandidate`
    /// and teaches `LearningStore` immediately.
    public func applyCandidateSelection(_ chosenCandidate: String) {
        guard let alt = activeAlternative else { return }
        guard !lastRawClause.isEmpty, !lastConvertedClause.isEmpty else { return }

        // Check secure input before modifying text
        let secure = SecureInputMonitor.isPasswordFieldOrSecureInputActive(
            excludedBundleIDs: config.excludedBundleIDs
        )
        guard !secure.isSecure else { return }

        let updatedClause = coordinator.applyUserCorrection(
            rawClause: lastRawClause,
            currentConverted: lastConvertedClause,
            wordIndex: alt.wordIndex,
            chosenWord: chosenCandidate
        )

        let currentFullOnScreen = lastConvertedClause + lastTrailingSuffix
        let targetFullOnScreen = updatedClause + lastTrailingSuffix

        if currentFullOnScreen != targetFullOnScreen {
            _ = applyMinimalDiffReplacement(
                currentOnScreen: currentFullOnScreen,
                targetText: targetFullOnScreen,
                trailingText: "",
                postReturnAfter: false
            )
            if displayedClauseBuffer.hasSuffix(currentFullOnScreen) {
                displayedClauseBuffer.removeLast(currentFullOnScreen.count)
                displayedClauseBuffer.append(targetFullOnScreen)
            }
            lastConvertedClause = updatedClause
        }

        let updatedResult = ConversionResult(
            originalText: lastRawClause,
            convertedText: updatedClause,
            confidence: 1.0,
            source: .localExact,
            vietnameseRatio: 1.0,
            alternatives: [],
            latencyMs: 0
        )
        onLastConversionChanged?(updatedResult)
        clearActiveCandidateHUD()
        onStatsDidChange?()
    }

    /// Reverts the last converted clause back to its raw ASCII form and teaches `LearningStore`
    /// that the reverted terms should remain raw/English.
    @discardableResult
    public func undoLastConversion() -> Bool {
        guard !lastRawClause.isEmpty, lastRawClause != lastConvertedClause else {
            return false
        }

        let secure = SecureInputMonitor.isPasswordFieldOrSecureInputActive(
            excludedBundleIDs: config.excludedBundleIDs
        )
        guard !secure.isSecure else { return false }

        let currentFullOnScreen = lastConvertedClause + lastTrailingSuffix
        let rawFullOnScreen = lastRawClause + lastTrailingSuffix

        _ = applyMinimalDiffReplacement(
            currentOnScreen: currentFullOnScreen,
            targetText: rawFullOnScreen,
            trailingText: "",
            postReturnAfter: false
        )

        if displayedClauseBuffer.hasSuffix(currentFullOnScreen) {
            displayedClauseBuffer.removeLast(currentFullOnScreen.count)
            displayedClauseBuffer.append(rawFullOnScreen)
        }

        // Teach LearningStore that the words changed by conversion should remain raw/English
        let rawWords = lastRawClause.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let convWords = lastConvertedClause.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if rawWords.count == convWords.count {
            for idx in rawWords.indices where rawWords[idx] != convWords[idx] {
                let prev1 = idx >= 1 ? rawWords[idx - 1].lowercased() : nil
                let prev2 = idx >= 2 ? rawWords[idx - 2].lowercased() : nil
                coordinator.store.recordUserCorrection(
                    baseWord: VNIEngine.stripDiacritics(rawWords[idx]).lowercased(),
                    chosenSurface: rawWords[idx],
                    prev1: prev1,
                    prev2: prev2,
                    next1: idx + 1 < rawWords.count ? rawWords[idx + 1] : nil,
                    fullRawClause: lastRawClause,
                    fullCorrectedClause: lastRawClause
                )
            }
        }

        let revertedResult = ConversionResult(
            originalText: lastRawClause,
            convertedText: lastRawClause,
            confidence: 1.0,
            source: .passthrough,
            vietnameseRatio: 0,
            alternatives: [],
            latencyMs: 0
        )
        lastConvertedClause = lastRawClause
        clearActiveCandidateHUD()
        onLastConversionChanged?(revertedResult)
        onStatsDidChange?()
        return true
    }

    // MARK: - Helpers & State Management

    private func recordLastConversionState(
        result: ConversionResult,
        rawClause: String,
        convertedClause: String,
        trailingSuffix: String
    ) {
        lastRawClause = rawClause
        lastConvertedClause = convertedClause
        lastTrailingSuffix = trailingSuffix
        lastConversionVersion = bufferVersion

        onLastConversionChanged?(result)

        // Always keep the alternatives so ⌥1..5 works; whether the popup is shown is decided by AppState
        // (`showCandidateHUD`), so turning the popup off does not disable keyboard candidate picking.
        if let lastAlt = result.alternatives.last, lastAlt.candidates.count > 1 {
            activeAlternative = lastAlt
            onActiveCandidatesChanged?(lastAlt)
        } else {
            clearActiveCandidateHUD()
        }
    }

    private func clearActiveCandidateHUD() {
        if activeAlternative != nil {
            activeAlternative = nil
            onActiveCandidatesChanged?(nil)
        }
    }

    private func finalizeInlineVNIIfNeeded() {
        if currentWordWasInlineVNI && !currentWordBuffer.isEmpty {
            coordinator.learnFromVNIWord(currentWordBuffer, precedingContext: precedingContext)
            currentWordWasInlineVNI = false
            onStatsDidChange?()
        }
    }

    private func handleBackspace() {
        pendingSmartTask?.cancel()
        bufferVersion &+= 1
        clearActiveCandidateHUD()

        if !vniWordBuffer.isEmpty {
            vniWordBuffer.removeLast()
        }
        if !rawClauseBuffer.isEmpty {
            rawClauseBuffer.removeLast()
        }
        if !displayedClauseBuffer.isEmpty {
            displayedClauseBuffer.removeLast()
        }
        if !currentWordBuffer.isEmpty {
            currentWordBuffer.removeLast()
        }
        if currentWordBuffer.isEmpty {
            currentWordWasInlineVNI = false
        }
    }

    private func resetAllBuffers(clearContext: Bool) {
        pendingSmartTask?.cancel()
        pendingSmartTask = nil
        bufferVersion &+= 1

        vniWordBuffer = ""
        rawClauseBuffer = ""
        displayedClauseBuffer = ""
        currentWordBuffer = ""
        currentWordWasInlineVNI = false

        if clearContext {
            recentVNIContext = ""
            precedingContext = ""
            lastRawClause = ""
            lastConvertedClause = ""
            lastTrailingSuffix = ""
        }
        clearActiveCandidateHUD()
    }

    private func trimClauseBufferIfNeeded() {
        guard rawClauseBuffer.count > Self.maxClauseBufferLength else { return }
        // Trim at a space boundary in the first half so active words remain intact
        let cutIndex = rawClauseBuffer.index(rawClauseBuffer.startIndex, offsetBy: 40)
        if let spaceIdx = rawClauseBuffer[cutIndex...].firstIndex(of: " ") {
            let nextIdx = rawClauseBuffer.index(after: spaceIdx)
            let rawPrefix = String(rawClauseBuffer[..<nextIdx])
            rawClauseBuffer = String(rawClauseBuffer[nextIdx...])

            if displayedClauseBuffer.count > rawPrefix.count,
               let dispSpace = displayedClauseBuffer.dropFirst(30).firstIndex(of: " ") {
                let dispNext = displayedClauseBuffer.index(after: dispSpace)
                let dispPrefix = String(displayedClauseBuffer[..<dispNext])
                appendToContext(&precedingContext, text: dispPrefix)
                displayedClauseBuffer = String(displayedClauseBuffer[dispNext...])
            } else {
                appendToContext(&precedingContext, text: rawPrefix)
                displayedClauseBuffer = rawClauseBuffer
            }
        }
    }

    private func appendToContext(_ context: inout String, text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if context.isEmpty {
            context = cleaned
        } else {
            context += " " + cleaned
        }
        if context.count > 120 {
            context = String(context.suffix(120))
        }
    }

    private func isNavigationOrResetKey(keyCode: Int64) -> Bool {
        switch keyCode {
        case KeyCode.leftArrow, KeyCode.rightArrow, KeyCode.upArrow, KeyCode.downArrow,
             KeyCode.home, KeyCode.end, KeyCode.pageUp, KeyCode.pageDown,
             KeyCode.forwardDelete, KeyCode.tab, KeyCode.escape:
            return true
        default:
            return false
        }
    }

    private func extractUnicodeString(from event: CGEvent) -> String {
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(
            maxStringLength: 4,
            actualStringLength: &length,
            unicodeString: &chars
        )
        guard length > 0 else { return "" }
        return String(utf16CodeUnits: chars, count: length)
    }

    private func applyingEdit(to source: String, backspaces: Int, insertion: String) -> String {
        var s = source
        let dropCount = min(backspaces, s.count)
        if dropCount > 0 {
            s.removeLast(dropCount)
        }
        s.append(insertion)
        return s
    }

    // MARK: - Minimal Diff Replacement & Safe Synthetic Unicode Injection

    /// Computes the common character prefix between `currentOnScreen` and `targetText`,
    /// sends only the minimal number of backspaces + replacement Unicode text, and optionally
    /// appends `trailingText` and a synthetic Return key.
    @discardableResult
    private func applyMinimalDiffReplacement(
        currentOnScreen: String,
        targetText: String,
        trailingText: String,
        postReturnAfter: Bool,
        returnFlags: CGEventFlags = []
    ) -> Bool {
        let currentChars = Array(currentOnScreen)
        let targetChars = Array(targetText)

        var prefixLen = 0
        let minLen = min(currentChars.count, targetChars.count)
        while prefixLen < minLen && currentChars[prefixLen] == targetChars[prefixLen] {
            prefixLen += 1
        }

        let backspacesNeeded = currentChars.count - prefixLen
        let insertionText = String(targetChars[prefixLen...]) + trailingText

        if backspacesNeeded == 0 && insertionText.isEmpty && !postReturnAfter {
            return false
        }

        if backspacesNeeded > 0 {
            injectBackspaces(backspacesNeeded)
            usleep(1200)
        }

        if !insertionText.isEmpty {
            injectUnicodeText(insertionText)
        }

        if postReturnAfter {
            usleep(1000)
            injectVirtualKey(KeyCode.returnKey, flags: returnFlags)
        }

        return true
    }

    private func injectBackspaces(_ count: Int) {
        guard count > 0 else { return }
        for _ in 0..<count {
            injectVirtualKey(KeyCode.delete)
            usleep(600)
        }
    }

    /// Posts a synthetic key press with exactly `flags` as modifiers (none by default), regardless of which
    /// modifier keys the user is still holding.
    private func injectVirtualKey(_ keyCode: Int64, flags: CGEventFlags = []) {
        let source = Self.syntheticEventSource
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: false) else {
            return
        }
        down.flags = flags
        up.flags = flags
        down.setIntegerValueField(.eventSourceUserData, value: Self.kodauEventTag)
        up.setIntegerValueField(.eventSourceUserData, value: Self.kodauEventTag)
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    /// Injects arbitrary Unicode text via `CGEventKeyboardSetUnicodeString` in safe chunks of <= 16 UTF-16 code units.
    /// Never modifies the user's clipboard.
    private func injectUnicodeText(_ text: String) {
        guard !text.isEmpty else { return }
        let utf16Units = Array(text.utf16)
        let chunkSize = 16
        var offset = 0

        while offset < utf16Units.count {
            let end = min(offset + chunkSize, utf16Units.count)
            var slice = Array(utf16Units[offset..<end])

            if let down = CGEvent(keyboardEventSource: Self.syntheticEventSource, virtualKey: 0, keyDown: true),
               let up = CGEvent(keyboardEventSource: Self.syntheticEventSource, virtualKey: 0, keyDown: false) {
                // No modifiers: a held Option/Shift must not alter the inserted Vietnamese text.
                down.flags = []
                up.flags = []
                down.setIntegerValueField(.eventSourceUserData, value: Self.kodauEventTag)
                up.setIntegerValueField(.eventSourceUserData, value: Self.kodauEventTag)
                down.keyboardSetUnicodeString(stringLength: slice.count, unicodeString: &slice)
                up.keyboardSetUnicodeString(stringLength: slice.count, unicodeString: &slice)
                down.post(tap: .cgSessionEventTap)
                up.post(tap: .cgSessionEventTap)
            }

            offset = end
            if offset < utf16Units.count {
                usleep(1000)
            }
        }
    }
}
