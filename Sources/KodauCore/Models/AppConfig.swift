import Foundation

/// WHEN Smart Mode (automatic trigger) sends a clause to Gemini.
public enum GeminiTiming: String, Codable, CaseIterable, Identifiable, Sendable {
    /// One call per sentence: local result is shown instantly; Gemini runs at `. ! ?`, Return,
    /// or after a longer typing pause (`sentencePauseMilliseconds`).
    case perSentence = "per_sentence"
    /// Legacy behavior: call after every short pause following Space / `, ; :` (`debounceMilliseconds`).
    case realtime = "realtime"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .perSentence: return "Theo câu (tiết kiệm)"
        case .realtime: return "Thời gian thực"
        }
    }

    public var subtitle: String {
        switch self {
        case .perSentence:
            return "Hiện dấu ngay bằng não offline; mỗi câu chỉ gọi Gemini 1 lần khi gặp . ! ?, Enter hoặc khi bạn dừng gõ lâu."
        case .realtime:
            return "Gọi Gemini sau mỗi lần ngừng gõ ngắn sau dấu cách / dấu phẩy. Sửa dấu sớm hơn nhưng tốn nhiều lượt gọi hơn."
        }
    }
}

/// Persistent user configuration for Kodau.
public struct AppConfig: Codable, Equatable, Sendable {
    public var typingMode: TypingMode
    public var brainStrategy: BrainStrategy
    public var geminiAPIKey: String
    /// Default requested by user: `gemini-3.5-flash-lite` (latest fast Flash Lite model).
    public var geminiModel: String
    /// Minimum local confidence [0.5 ... 0.98] required to skip calling Gemini API in Hybrid mode.
    public var localConfidenceThreshold: Double
    /// Milliseconds to wait after the user pauses typing before triggering a Gemini clause refinement.
    public var debounceMilliseconds: Int
    /// Allow typing VNI sequences (e.g. `ban5`, `tie6ng1`) directly inside Smart Mode as instant overrides.
    public var inlineVNIOverrideEnabled: Bool
    /// Show non-activating floating quick-fix candidate bar when ambiguous words are converted.
    public var showCandidateHUD: Bool
    /// Auto-learn every VNI word typed in VNI mode into the offline không-dấu brain.
    public var learnFromVNIMode: Bool
    /// Prompt user to switch to 100% Offline when independence score reaches Stage 4.
    public var autoSuggestOfflineMode: Bool
    /// Bundle identifiers of apps where Kodau should stay in English/pass-through mode (e.g. password managers, terminals).
    public var excludedBundleIDs: [String]
    /// Use modern Vietnamese tone placement (`hòa` instead of `hoà`).
    public var modernTonePlacement: Bool
    /// Controls whether diacritics are added automatically while typing or only manually via shortcut (Option+Space).
    public var triggerMode: ConversionTriggerMode
    /// USD -> VND exchange rate used to display estimated API costs in VND.
    public var usdToVndRate: Double
    /// Show a confirm toast (bottom-center) when the user goes back and fixes a word Kodau restored, then learn it.
    public var learnFromEditsEnabled: Bool
    /// When automatic Smart Mode calls Gemini (per sentence vs after every short pause).
    public var geminiTiming: GeminiTiming
    /// Per-sentence timing: typing pause (ms) after which an unfinished sentence is sent to Gemini.
    public var sentencePauseMilliseconds: Int
    /// Max Gemini API calls per calendar day across Kodau + KodauIM (0 = unlimited). When reached, Kodau stays offline until tomorrow.
    public var dailyGeminiCallLimit: Int
    /// Max estimated Gemini spend per calendar day in VND (0 = unlimited). When reached, Kodau stays offline until tomorrow.
    public var dailyGeminiBudgetVND: Double
    /// Minimum seconds between two Gemini API calls (0 = no spacing).
    public var minGeminiIntervalSeconds: Double
    /// Legacy typing path: Kodau.app intercepts every keystroke with a CGEventTap (needs Accessibility) and edits
    /// text with synthetic Backspaces. Off by default — the native KodauIM input source is the primary path.
    public var legacyEventTapEnabled: Bool

    public static let availableGeminiModels: [String] = [
        "gemini-3.5-flash-lite",
        "gemini-3.1-flash-lite",
        "gemini-2.5-flash-lite",
        "gemini-2.5-flash",
        "gemini-2.0-flash",
        "gemini-1.5-flash"
    ]

    public init(
        typingMode: TypingMode = .smart,
        brainStrategy: BrainStrategy = .hybrid,
        geminiAPIKey: String = "",
        geminiModel: String = "gemini-3.5-flash-lite",
        localConfidenceThreshold: Double = 0.80,
        debounceMilliseconds: Int = 450,
        inlineVNIOverrideEnabled: Bool = true,
        showCandidateHUD: Bool = true,
        learnFromVNIMode: Bool = true,
        autoSuggestOfflineMode: Bool = true,
        excludedBundleIDs: [String] = [
            "com.1password.1password",
            "com.bitwarden.desktop",
            "com.apple.keychainaccess"
        ],
        modernTonePlacement: Bool = true,
        triggerMode: ConversionTriggerMode = .automatic,
        usdToVndRate: Double = 25_800,
        learnFromEditsEnabled: Bool = true,
        geminiTiming: GeminiTiming = .perSentence,
        sentencePauseMilliseconds: Int = 1500,
        dailyGeminiCallLimit: Int = 500,
        dailyGeminiBudgetVND: Double = 5_000,
        minGeminiIntervalSeconds: Double = 1.0,
        legacyEventTapEnabled: Bool = false
    ) {
        self.typingMode = typingMode
        self.brainStrategy = brainStrategy
        self.geminiAPIKey = geminiAPIKey
        self.geminiModel = geminiModel
        self.localConfidenceThreshold = localConfidenceThreshold
        self.debounceMilliseconds = debounceMilliseconds
        self.inlineVNIOverrideEnabled = inlineVNIOverrideEnabled
        self.showCandidateHUD = showCandidateHUD
        self.learnFromVNIMode = learnFromVNIMode
        self.autoSuggestOfflineMode = autoSuggestOfflineMode
        self.excludedBundleIDs = excludedBundleIDs
        self.modernTonePlacement = modernTonePlacement
        self.triggerMode = triggerMode
        self.usdToVndRate = usdToVndRate
        self.learnFromEditsEnabled = learnFromEditsEnabled
        self.geminiTiming = geminiTiming
        self.sentencePauseMilliseconds = sentencePauseMilliseconds
        self.dailyGeminiCallLimit = dailyGeminiCallLimit
        self.dailyGeminiBudgetVND = dailyGeminiBudgetVND
        self.minGeminiIntervalSeconds = minGeminiIntervalSeconds
        self.legacyEventTapEnabled = legacyEventTapEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppConfig()
        self.typingMode = try c.decodeIfPresent(TypingMode.self, forKey: .typingMode) ?? defaults.typingMode
        self.brainStrategy = try c.decodeIfPresent(BrainStrategy.self, forKey: .brainStrategy) ?? defaults.brainStrategy
        self.geminiAPIKey = try c.decodeIfPresent(String.self, forKey: .geminiAPIKey) ?? defaults.geminiAPIKey
        self.geminiModel = try c.decodeIfPresent(String.self, forKey: .geminiModel) ?? defaults.geminiModel
        self.localConfidenceThreshold = try c.decodeIfPresent(Double.self, forKey: .localConfidenceThreshold) ?? defaults.localConfidenceThreshold
        self.debounceMilliseconds = try c.decodeIfPresent(Int.self, forKey: .debounceMilliseconds) ?? defaults.debounceMilliseconds
        self.inlineVNIOverrideEnabled = try c.decodeIfPresent(Bool.self, forKey: .inlineVNIOverrideEnabled) ?? defaults.inlineVNIOverrideEnabled
        self.showCandidateHUD = try c.decodeIfPresent(Bool.self, forKey: .showCandidateHUD) ?? defaults.showCandidateHUD
        self.learnFromVNIMode = try c.decodeIfPresent(Bool.self, forKey: .learnFromVNIMode) ?? defaults.learnFromVNIMode
        self.autoSuggestOfflineMode = try c.decodeIfPresent(Bool.self, forKey: .autoSuggestOfflineMode) ?? defaults.autoSuggestOfflineMode
        self.excludedBundleIDs = try c.decodeIfPresent([String].self, forKey: .excludedBundleIDs) ?? defaults.excludedBundleIDs
        self.modernTonePlacement = try c.decodeIfPresent(Bool.self, forKey: .modernTonePlacement) ?? defaults.modernTonePlacement
        self.triggerMode = try c.decodeIfPresent(ConversionTriggerMode.self, forKey: .triggerMode) ?? defaults.triggerMode
        self.usdToVndRate = try c.decodeIfPresent(Double.self, forKey: .usdToVndRate) ?? defaults.usdToVndRate
        self.learnFromEditsEnabled = try c.decodeIfPresent(Bool.self, forKey: .learnFromEditsEnabled) ?? defaults.learnFromEditsEnabled
        self.geminiTiming = try c.decodeIfPresent(GeminiTiming.self, forKey: .geminiTiming) ?? defaults.geminiTiming
        self.sentencePauseMilliseconds = try c.decodeIfPresent(Int.self, forKey: .sentencePauseMilliseconds) ?? defaults.sentencePauseMilliseconds
        self.dailyGeminiCallLimit = try c.decodeIfPresent(Int.self, forKey: .dailyGeminiCallLimit) ?? defaults.dailyGeminiCallLimit
        self.dailyGeminiBudgetVND = try c.decodeIfPresent(Double.self, forKey: .dailyGeminiBudgetVND) ?? defaults.dailyGeminiBudgetVND
        self.minGeminiIntervalSeconds = try c.decodeIfPresent(Double.self, forKey: .minGeminiIntervalSeconds) ?? defaults.minGeminiIntervalSeconds
        self.legacyEventTapEnabled = try c.decodeIfPresent(Bool.self, forKey: .legacyEventTapEnabled) ?? defaults.legacyEventTapEnabled
    }

    /// Resolves the effective API key (config first, then environment variable `GEMINI_API_KEY`).
    public var effectiveAPIKey: String {
        let trimmed = geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return ProcessInfo.processInfo.environment["GEMINI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    public var hasAPIKey: Bool {
        !effectiveAPIKey.isEmpty
    }

    /// Default application support directory: `~/Library/Application Support/Kodau`.
    public static var appSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Kodau", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static var configFileURL: URL {
        appSupportDirectory.appendingPathComponent("config.json")
    }

    public static var databaseFileURL: URL {
        appSupportDirectory.appendingPathComponent("kodau_brain.sqlite")
    }

    public static func load(from url: URL = AppConfig.configFileURL) -> AppConfig {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return AppConfig()
        }
        return decoded
    }

    public func save(to url: URL = AppConfig.configFileURL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
        // Protect config file containing API key with 0600 permissions (owner read/write only)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
