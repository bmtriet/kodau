import Cocoa
import InputMethodKit
import KodauCore

/// Shared notification name used to keep `Kodau.app` (Dashboard) and `KodauIM.app` (macOS Input Method)
/// synchronized whenever the user updates their Gemini API key, model, typing mode, or brain strategy.
let kodauConfigDidChangeNotification = Notification.Name("com.kodau.configDidChange")
/// Posted by `KodauIM` whenever learning stats or Gemini token usage change, so `Kodau.app` can refresh.
let kodauStatsDidChangeNotification = Notification.Name("com.kodau.statsDidChange")

/// Singleton runtime shared across all `KodauIMController` client sessions in the input method server.
final class KodauIMRuntime {
    static let shared = KodauIMRuntime()

    let store: LearningStore
    let geminiClient: GeminiClient
    let coordinator: SmartCoordinator

    private var lastConfigModDate: Date?

    private init() {
        let loadedConfig = AppConfig.load()
        self.geminiClient = GeminiClient()
        do {
            self.store = try LearningStore(databaseURL: AppConfig.databaseFileURL)
        } catch {
            // Fallback to in-memory store if disk is somehow unavailable; never crash the IME server.
            self.store = try! LearningStore(databaseURL: URL(fileURLWithPath: ":memory:"))
        }
        self.coordinator = SmartCoordinator(
            store: store,
            config: loadedConfig,
            geminiClient: geminiClient
        )
        self.lastConfigModDate = Self.configModificationDate()

        MainActor.assumeIsolated {
            CorrectionToastController.shared.onConfirm = { [weak self] candidate in
                self?.learnConfirmedCorrection(candidate)
            }
        }

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleConfigNotification),
            name: kodauConfigDidChangeNotification,
            object: nil
        )
    }

    var config: AppConfig {
        coordinator.config
    }

    @objc private func handleConfigNotification() {
        reloadConfig(force: true)
    }

    func reloadConfigIfNeeded() {
        let modDate = Self.configModificationDate()
        if modDate != lastConfigModDate {
            reloadConfig(force: true)
        }
    }

    func reloadConfig(force: Bool = false) {
        if force || Self.configModificationDate() != lastConfigModDate {
            let fresh = AppConfig.load()
            coordinator.updateConfig(fresh)
            lastConfigModDate = Self.configModificationDate()
        }
    }

    func updateConfig(_ mutate: (inout AppConfig) -> Void) {
        var updated = coordinator.config
        mutate(&updated)
        coordinator.updateConfig(updated)
        try? updated.save()
        lastConfigModDate = Self.configModificationDate()
        DistributedNotificationCenter.default().postNotificationName(
            kodauConfigDidChangeNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    private var pendingStatsNotification: DispatchWorkItem?

    /// Teaches the shared brain a correction the user confirmed in the toast (high-priority, user-verified),
    /// including its preceding context so the same phrase is restored correctly next time.
    func learnConfirmedCorrection(_ candidate: EditCorrectionCandidate) {
        let context = [candidate.prev2, candidate.prev1].compactMap { $0 }
        let correctedClause = (context + [candidate.correctedSurface.lowercased()]).joined(separator: " ")
        let rawClause = VNIEngine.stripDiacritics(correctedClause).lowercased()
        store.recordUserCorrection(
            baseWord: candidate.baseWord,
            chosenSurface: candidate.correctedSurface,
            prev1: candidate.prev1,
            prev2: candidate.prev2,
            next1: candidate.next1,
            // Phrase memory only with context; a bare single word would override every future standalone use.
            fullRawClause: context.isEmpty ? nil : rawClause,
            fullCorrectedClause: context.isEmpty ? nil : correctedClause
        )
        notifyStatsChanged()
    }

    /// Tells `Kodau.app` (a separate process sharing the same SQLite brain) that stats / API usage changed,
    /// so the Dashboard and the Token & Cost tab refresh live. Debounced to at most ~2 posts per second.
    func notifyStatsChanged() {
        let post = {
            self.pendingStatsNotification?.cancel()
            let work = DispatchWorkItem {
                DistributedNotificationCenter.default().postNotificationName(
                    kodauStatsDidChangeNotification,
                    object: nil,
                    userInfo: nil,
                    deliverImmediately: true
                )
            }
            self.pendingStatsNotification = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
    }

    func openDashboardApp() {
        // `KodauDashboardAppPath` is written into Info.plist by scripts/install_im.sh (the repo's build/Kodau.app).
        let devBuildPath = Bundle.main.object(forInfoDictionaryKey: "KodauDashboardAppPath") as? String
        let candidates = [
            "/Applications/Kodau.app",
            NSHomeDirectory() + "/Applications/Kodau.app"
        ] + [devBuildPath].compactMap { $0 }
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
            return
        }
        // Fallback by bundle identifier if moved elsewhere
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.kodau.inputmethod") {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: config, completionHandler: nil)
        }
    }

    private static func configModificationDate() -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: AppConfig.configFileURL.path)
        return attrs?[.modificationDate] as? Date
    }
}

// MARK: - InputMethodKit Server Entry Point

let connectionName = Bundle.main.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String
    ?? "KodauIM_Connection"
let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.kodau.inputmethod.KodauIM"

// Ensure NSApplication is initialized before creating IMKServer
let app = NSApplication.shared
// Touch runtime early so SQLite + config + DistributedNotificationCenter are ready
_ = KodauIMRuntime.shared

guard let imkServer = IMKServer(name: connectionName, bundleIdentifier: bundleIdentifier) else {
    NSLog("KodauIM: Failed to initialize IMKServer with connectionName=%@ bundleID=%@", connectionName, bundleIdentifier)
    exit(1)
}

// Keep strong reference to server for app lifetime
withExtendedLifetime(imkServer) {
    app.run()
}
