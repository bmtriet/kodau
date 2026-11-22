import Foundation
import AppKit
import Combine
import KodauCore

public enum DashboardTab: String, CaseIterable, Identifiable {
    case typing
    case dictionary
    case stats
    case mistakes
    case settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .typing: return "Gõ thử"
        case .dictionary: return "Từ điển"
        case .stats: return "Thống kê"
        case .mistakes: return "Lỗi hay gặp"
        case .settings: return "Cài đặt"
        }
    }

    public var iconName: String {
        switch self {
        case .typing: return "keyboard"
        case .dictionary: return "book.closed"
        case .stats: return "chart.bar"
        case .mistakes: return "exclamationmark.bubble"
        case .settings: return "gearshape"
        }
    }
}

@MainActor
public final class AppState: ObservableObject {

    @Published public var config: AppConfig
    @Published public var stats: LearningStats
    @Published public var usageSummaries: [UsageSummary] = []
    @Published public var kodauIMStatus: KodauIMStatus = .notInstalled
    @Published public var inputSourceErrorMessage: String? = nil
    @Published public var accessibilityGranted: Bool = false
    @Published public var isInterceptorRunning: Bool = false
    @Published public var isSecureInputActive: Bool = false
    @Published public var secureInputReason: String? = nil
    @Published public var lastConversion: ConversionResult? = nil
    @Published public var showAPIKeyDialog: Bool = false
    @Published public var showOfflineReadyBanner: Bool = false
    @Published public var activeCandidates: WordAlternative? = nil
    @Published public var selectedTab: DashboardTab = .typing
    @Published public var saveErrorMessage: String? = nil

    public let store: LearningStore
    public let geminiClient: GeminiClient
    public let coordinator: SmartCoordinator
    public let interceptor: KeyboardInterceptor
    public let candidatePanel: CandidatePanelController
    public let inputSourceMonitor: InputSourceMonitor

    private var accessibilityPollTimer: Timer?
    private var distributedObserver: NSObjectProtocol?
    private var statsObserver: NSObjectProtocol?

    /// Invoked whenever menu bar title or menu state should be refreshed.
    public var onMenuBarStateChanged: (() -> Void)?

    public init() {
        let loadedConfig = AppConfig.load()
        self.config = loadedConfig

        let learningStore: LearningStore
        if let diskStore = try? LearningStore(databaseURL: AppConfig.databaseFileURL) {
            learningStore = diskStore
        } else {
            // Safe fallback to a temp directory so the app never fails to launch
            let fallbackURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("kodau_fallback_brain.sqlite")
            learningStore = try! LearningStore(databaseURL: fallbackURL)
        }
        self.store = learningStore

        let client = GeminiClient()
        self.geminiClient = client

        let smartCoordinator = SmartCoordinator(
            store: learningStore,
            config: loadedConfig,
            geminiClient: client
        )
        self.coordinator = smartCoordinator
        self.stats = smartCoordinator.currentStats()

        let keyboardInterceptor = KeyboardInterceptor(
            coordinator: smartCoordinator,
            config: loadedConfig
        )
        self.interceptor = keyboardInterceptor
        self.candidatePanel = CandidatePanelController()

        let monitor = InputSourceMonitor()
        self.inputSourceMonitor = monitor
        self.kodauIMStatus = monitor.status

        // Automatically show the Gemini API Key dialog on first launch if no key is configured yet
        self.showAPIKeyDialog = !loadedConfig.hasAPIKey && loadedConfig.brainStrategy != .offlineOnly

        wireCallbacks()
        observeExternalConfigChanges()
        monitor.onStatusChanged = { [weak self] newStatus in
            guard let self else { return }
            self.kodauIMStatus = newStatus
            if newStatus == .active {
                self.inputSourceErrorMessage = nil
            }
            self.onMenuBarStateChanged?()
        }
        monitor.start()
        syncLegacyTypingPath()
        refreshStats()
    }

    deinit {
        accessibilityPollTimer?.invalidate()
        if let observer = distributedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        if let observer = statsObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }

    private func observeExternalConfigChanges() {
        distributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.kodau.configDidChange"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let reloaded = AppConfig.load()
                if reloaded != self.config {
                    self.config = reloaded
                    self.coordinator.updateConfig(reloaded)
                    self.interceptor.updateConfig(reloaded)
                    self.syncLegacyTypingPath()
                    self.onMenuBarStateChanged?()
                }
                self.refreshStats()
            }
        }

        // KodauIM (separate input-method process) records conversions & Gemini token usage into the
        // shared SQLite brain; refresh Dashboard + Token & Cost tab live when it tells us so.
        statsObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.kodau.statsDidChange"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshStats()
            }
        }
    }

    // MARK: - Wiring

    private func wireCallbacks() {
        interceptor.onModeChanged = { [weak self] newMode in
            Task { @MainActor in
                guard let self else { return }
                if self.config.typingMode != newMode {
                    self.config.typingMode = newMode
                    self.saveConfig()
                }
            }
        }

        interceptor.onSecureInputStateChanged = { [weak self] isSecure, reason in
            Task { @MainActor in
                guard let self else { return }
                self.isSecureInputActive = isSecure
                self.secureInputReason = reason
                if isSecure {
                    self.activeCandidates = nil
                    self.candidatePanel.hide()
                }
                self.onMenuBarStateChanged?()
            }
        }

        interceptor.onLastConversionChanged = { [weak self] result in
            Task { @MainActor in
                self?.lastConversion = result
            }
        }

        interceptor.onActiveCandidatesChanged = { [weak self] alt in
            Task { @MainActor in
                guard let self else { return }
                self.activeCandidates = alt
                if let alt, self.config.showCandidateHUD, !self.isSecureInputActive {
                    self.candidatePanel.show(alternative: alt)
                } else {
                    self.candidatePanel.hide()
                }
            }
        }

        interceptor.onStatsDidChange = { [weak self] in
            Task { @MainActor in
                self?.refreshStats()
            }
        }

        candidatePanel.onSelectCandidate = { [weak self] chosen in
            self?.interceptor.applyCandidateSelection(chosen)
        }

        candidatePanel.onUndo = { [weak self] in
            self?.interceptor.undoLastConversion()
        }
    }

    // MARK: - Config & Mode Actions

    public func saveConfig() {
        do {
            try config.save()
            saveErrorMessage = nil
        } catch {
            saveErrorMessage = "Không thể lưu cấu hình: \(error.localizedDescription)"
        }
        coordinator.updateConfig(config)
        interceptor.updateConfig(config)
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.kodau.configDidChange"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        if !config.showCandidateHUD {
            candidatePanel.hide()
        }
        syncLegacyTypingPath()
        updateOfflineReadyBanner()
        onMenuBarStateChanged?()
    }

    public func cycleMode() {
        setMode(config.typingMode.next)
    }

    public func setMode(_ mode: TypingMode) {
        config.typingMode = mode
        saveConfig()
    }

    public func setStrategy(_ strategy: BrainStrategy) {
        config.brainStrategy = strategy
        saveConfig()
    }

    public func setTriggerMode(_ mode: ConversionTriggerMode) {
        config.triggerMode = mode
        saveConfig()
    }

    public func switchToOfflineOnly() {
        config.brainStrategy = .offlineOnly
        showOfflineReadyBanner = false
        saveConfig()
    }

    // MARK: - Gemini API Test

    public func testGeminiAPI(apiKey: String, model: String) async -> GeminiTestResult {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackModel = AppConfig.availableGeminiModels.first ?? "gemini-3.5-flash-lite"
        let effectiveModel = trimmedModel.isEmpty ? fallbackModel : trimmedModel
        let result = await geminiClient.testConnection(apiKey: trimmedKey, model: effectiveModel)
        if let usage = result.tokenUsage {
            store.recordAPIUsage(usage, usdToVndRate: config.usdToVndRate)
            refreshStats()
        }
        return result
    }

    // MARK: - Input Source (KodauIM)

    /// KodauIM is the primary typing path; these forward the monitor's actions to the UI.
    public func refreshInputSourceStatus() {
        kodauIMStatus = inputSourceMonitor.refresh()
    }

    public func openInputSourcesSettings() {
        inputSourceErrorMessage = nil
        InputSourceMonitor.openInputSourcesSettings()
    }

    /// Reports whether macOS accepted the switch (it can refuse while a secure field has focus).
    @discardableResult
    public func selectKodauIM() -> Bool {
        let success = inputSourceMonitor.selectKodauIM()
        kodauIMStatus = inputSourceMonitor.status
        if success {
            inputSourceErrorMessage = nil
        } else {
            switch kodauIMStatus {
            case .active:
                inputSourceErrorMessage = nil
            case .installedNotEnabled:
                inputSourceErrorMessage = "Kodau chưa được thêm vào Input Sources. Mở Input Sources để thêm Kodau (Smart Vi/En)."
            default:
                inputSourceErrorMessage = "macOS chưa cho phép chuyển nguồn nhập lúc này (ví dụ khi đang ở ô mật khẩu). Hãy thử lại hoặc chọn Kodau từ menu nguồn nhập trên thanh menu."
            }
        }
        onMenuBarStateChanged?()
        return success
    }

    // MARK: - Legacy CGEventTap (optional fallback)

    /// Starts/stops the legacy keyboard tap to match `legacyEventTapEnabled`, and only polls
    /// Accessibility while that optional mode is on.
    public func syncLegacyTypingPath() {
        guard config.legacyEventTapEnabled else {
            accessibilityPollTimer?.invalidate()
            accessibilityPollTimer = nil
            if interceptor.isRunning {
                interceptor.stop()
            }
            isInterceptorRunning = false
            accessibilityGranted = false
            onMenuBarStateChanged?()
            return
        }

        refreshAccessibilityAndStartIfPossible()
        startAccessibilityPolling()
    }

    public func openAccessibilitySettings() {
        _ = SecureInputMonitor.isAccessibilityTrusted(prompt: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        refreshAccessibilityAndStartIfPossible()
    }

    private func refreshAccessibilityAndStartIfPossible() {
        guard config.legacyEventTapEnabled else {
            // KodauIM path: never touch Accessibility (and never prompt) when legacy mode is off.
            if interceptor.isRunning {
                interceptor.stop()
            }
            isInterceptorRunning = false
            accessibilityGranted = false
            onMenuBarStateChanged?()
            return
        }

        let trusted = SecureInputMonitor.isAccessibilityTrusted(prompt: false)
        accessibilityGranted = trusted

        if trusted {
            if !interceptor.isRunning {
                isInterceptorRunning = interceptor.start()
            } else {
                isInterceptorRunning = true
            }
        } else {
            if interceptor.isRunning {
                interceptor.stop()
            }
            isInterceptorRunning = false
        }
        onMenuBarStateChanged?()
    }

    private func startAccessibilityPolling() {
        guard accessibilityPollTimer == nil else { return }
        accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.config.legacyEventTapEnabled else { return }
                let trusted = SecureInputMonitor.isAccessibilityTrusted(prompt: false)
                if trusted != self.accessibilityGranted || (trusted && !self.interceptor.isRunning) {
                    self.refreshAccessibilityAndStartIfPossible()
                }
            }
        }
    }

    // MARK: - Stats

    public func refreshStats() {
        stats = coordinator.currentStats()
        usageSummaries = store.fetchAllPeriodSummaries(usdToVndRate: config.usdToVndRate)
        updateOfflineReadyBanner()
    }

    private func updateOfflineReadyBanner() {
        showOfflineReadyBanner = config.autoSuggestOfflineMode
            && config.brainStrategy != .offlineOnly
            && stats.stage == .independent
    }

    // MARK: - Display Helpers

    public var menuBarTitle: String {
        if isSecureInputActive {
            return "🔒"
        }
        return config.typingMode.shortBadge
    }

    public var maskedAPIKeyDisplay: String {
        let key = config.effectiveAPIKey
        guard !key.isEmpty else { return "Chưa cấu hình" }
        if key.count <= 8 {
            return String(repeating: "•", count: key.count)
        }
        let prefix = key.prefix(4)
        let suffix = key.suffix(4)
        return "\(prefix)••••••••\(suffix)"
    }
}
