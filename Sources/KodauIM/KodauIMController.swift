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
///
/// All composing state lives in the pure `SmartComposer`; this class only translates AppKit events into
/// `ComposerKey`s and applies the returned `ComposerAction`s (marked text, commits, async refinement, popup).
@objc(KodauIMController)
final class KodauIMController: IMKInputController {

    private var runtime: KodauIMRuntime { KodauIMRuntime.shared }

    private lazy var composer = SmartComposer(coordinator: runtime.coordinator)

    /// In-flight debounced Gemini refinement (one per controller).
    private var refinementTask: Task<Void, Never>?

    /// Pending debounced candidate popup show (automatic popups wait for a typing pause).
    private var pendingCandidateShow: DispatchWorkItem?
    /// Candidate popup currently on screen, used to update it in place instead of hiding and re-showing.
    private var visiblePresentation: CandidatePresentation?
    /// UTF-16 range of the word underlined thicker while the popup is visible.
    private var popupHighlightRange: NSRange?
    private static let candidateShowDelay: TimeInterval = 0.3

    /// Weak reference to the latest active client for async marked-text updates.
    private weak var activeClientObject: AnyObject?

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
    private static let commitPunctuation: Set<Character> = [".", ",", "!", "?", ";", ":"]

    private var hasActiveBuffer: Bool { composer.hasActiveBuffer }

    // MARK: - Lifecycle

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        runtime.reloadConfigIfNeeded()
        activeClientObject = sender as AnyObject?
        configureCandidatePopup()
    }

    override func deactivateServer(_ sender: Any!) {
        apply(composer.commitAll(), client: sender)
        finalizeEditSession(client: sender)
        refinementTask?.cancel()
        refinementTask = nil
        hideCandidatePopup()
        super.deactivateServer(sender)
    }

    override func commitComposition(_ sender: Any!) {
        apply(composer.commitAll(), client: sender)
        // Usually triggered by a mouse click / app switch: the edited word is final now.
        finalizeEditSession(client: sender)
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        return Int(NSEvent.EventTypeMask.keyDown.rawValue)
    }

    override func selectionRange() -> NSRange {
        return NSRange(location: composer.markedText.utf16.count, length: 0)
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

        // Any key cancels a pending automatic popup: it only appears after a real typing pause.
        cancelPendingCandidateShow()

        if handleCorrectionToastHotkey(event) {
            return true
        }

        beginEditTracking(event: event, client: sender)
        let result = composer.handleKey(composerKey(from: event))
        apply(result.actions, client: sender)
        endEditTracking(event: event, client: sender)
        return result.handled
    }

    private func composerKey(from event: NSEvent) -> ComposerKey {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: ComposerModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.control) { modifiers.insert(.control) }

        return ComposerKey(
            keyCode: event.keyCode,
            characters: event.characters,
            modifiers: modifiers,
            isRepeat: event.isARepeat
        )
    }

    // MARK: - Applying Composer Actions

    private func apply(_ actions: [ComposerAction], client sender: Any!) {
        for action in actions {
            switch action {
            case .setMarked(let text):
                setMarked(text, client: sender)

            case .clearMarked:
                clearMarked(client: sender)

            case .commit(let text):
                commitLiteral(text, client: sender)

            case .scheduleRefinement(let request):
                scheduleRefinement(request)

            case .cancelRefinement:
                refinementTask?.cancel()
                refinementTask = nil

            case .backgroundDistill(let raw, let context):
                backgroundDistill(raw: raw, context: context)

            case .showCandidates(let presentation):
                showCandidatePopup(presentation, client: sender)

            case .hideCandidates:
                hideCandidatePopup()

            case .cycleTypingMode:
                runtime.updateConfig { cfg in
                    cfg.typingMode = cfg.typingMode.next
                }

            case .statsChanged:
                runtime.notifyStatsChanged()
            }
        }
    }

    private func scheduleRefinement(_ request: RefinementRequest) {
        refinementTask?.cancel()

        let coordinator = runtime.coordinator
        refinementTask = Task {
            let delayNs = UInt64(max(0, request.delayMs)) * 1_000_000
            if delayNs > 0 {
                do {
                    try await Task.sleep(nanoseconds: delayNs)
                } catch {
                    return
                }
            }

            let trimmedRaw = request.raw.trimmingCharacters(in: .whitespaces)
            guard !trimmedRaw.isEmpty else { return }

            let result = await coordinator.convertSmart(
                trimmedRaw,
                precedingContext: request.context,
                forceSmartEngine: request.force
            )
            KodauIMRuntime.shared.notifyStatsChanged()
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let clientObj = self.activeClientObject else { return }
                let actions = self.composer.applyRefinement(result, for: request)
                self.apply(actions, client: clientObj)
            }
        }
    }

    private func backgroundDistill(raw: String, context: String) {
        let coordinator = runtime.coordinator
        Task.detached(priority: .utility) {
            _ = await coordinator.convertSmart(raw, precedingContext: context)
            KodauIMRuntime.shared.notifyStatsChanged()
        }
    }

    // MARK: - Candidate Popup

    private func configureCandidatePopup() {
        MainActor.assumeIsolated {
            let popup = CandidatePopupController.shared
            popup.onSelectCandidate = { [weak self] surface in
                MainActor.assumeIsolated {
                    guard let self, let client = self.activeClientObject else { return }
                    self.apply(self.composer.selectCandidate(surface), client: client)
                }
            }
            popup.onUndo = { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let client = self.activeClientObject else { return }
                    self.apply(self.composer.undoCandidatePopup(), client: client)
                }
            }
            // The popup hides itself after 5 s or on a click: drop the focused-word highlight again.
            popup.onHide = { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let hadHighlight = self.popupHighlightRange != nil
                    self.popupHighlightRange = nil
                    self.visiblePresentation = nil
                    guard hadHighlight, let client = self.activeClientObject else { return }
                    self.setMarked(self.composer.markedText, client: client)
                }
            }
        }
    }

    private func showCandidatePopup(_ presentation: CandidatePresentation, client sender: Any!) {
        pendingCandidateShow?.cancel()
        pendingCandidateShow = nil

        // Explicit focus moves and Gemini results show at once; automatic Space popups wait for a pause.
        if presentation.showsImmediately || isShowingSameCandidate(presentation) {
            presentCandidatePopup(presentation, client: sender)
            return
        }

        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingCandidateShow = nil
                guard let client = self.activeClientObject else { return }
                self.presentCandidatePopup(presentation, client: client)
            }
        }
        pendingCandidateShow = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.candidateShowDelay, execute: work)
    }

    private func presentCandidatePopup(_ presentation: CandidatePresentation, client sender: Any!) {
        popupHighlightRange = presentation.focusedRange
        let marked = composer.markedText
        if !marked.isEmpty {
            setMarked(marked, highlight: presentation.focusedRange, client: sender)
        }
        visiblePresentation = presentation

        var caretRect = NSRect.zero
        if let textInput = sender as? IMKTextInput {
            let selection = textInput.selectedRange()
            let index = selection.location != NSNotFound ? max(0, selection.location - 1) : 0
            _ = textInput.attributes(forCharacterIndex: index, lineHeightRectangle: &caretRect)
        }
        MainActor.assumeIsolated {
            CandidatePopupController.shared.show(presentation, near: caretRect)
        }
    }

    /// True when the visible popup already targets the same word with the same candidates: refresh in place.
    private func isShowingSameCandidate(_ presentation: CandidatePresentation) -> Bool {
        let isVisible = MainActor.assumeIsolated { CandidatePopupController.shared.isVisible }
        guard isVisible, let current = visiblePresentation else { return false }
        return current.alternative.wordIndex == presentation.alternative.wordIndex
            && current.alternative.baseWord == presentation.alternative.baseWord
            && current.alternative.candidates == presentation.alternative.candidates
            && current.geminiChanges == presentation.geminiChanges
    }

    private func cancelPendingCandidateShow() {
        pendingCandidateShow?.cancel()
        pendingCandidateShow = nil
    }

    private func hideCandidatePopup() {
        cancelPendingCandidateShow()
        MainActor.assumeIsolated {
            CandidatePopupController.shared.hide()
        }
    }

    // MARK: - Marked Text Helpers

    private func setMarked(_ text: String, highlight: NSRange? = nil, client sender: Any!) {
        guard let textInput = sender as? IMKTextInput else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: NSColor.controlAccentColor.withAlphaComponent(0.75)
        ]
        let attributed = NSMutableAttributedString(string: text, attributes: attrs)
        let length = (text as NSString).length
        if let highlight, highlight.location != NSNotFound, highlight.length > 0,
           NSMaxRange(highlight) <= length {
            attributed.addAttributes(
                [
                    .underlineStyle: NSUnderlineStyle.thick.rawValue,
                    .underlineColor: NSColor.controlAccentColor.withAlphaComponent(0.95)
                ],
                range: highlight
            )
        }
        let selRange = NSRange(location: length, length: 0)
        let repRange = NSRange(location: NSNotFound, length: 0)
        textInput.setMarkedText(attributed, selectionRange: selRange, replacementRange: repRange)
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

        // Opt-in typo fixing (Gemini may fix clear misspellings, word-for-word)
        let typoItem = NSMenuItem(
            title: "Sửa lỗi chính tả (Gemini)",
            action: #selector(toggleFixTypos(_:)),
            keyEquivalent: ""
        )
        typoItem.target = self
        typoItem.state = config.fixTyposEnabled ? .on : .off
        menu.addItem(typoItem)

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

    @objc private func toggleFixTypos(_ sender: NSMenuItem) {
        runtime.updateConfig { $0.fixTyposEnabled.toggle() }
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
