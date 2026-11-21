import Foundation
import Testing
@testable import KodauCore

/// `Option + Space` must be able to force diacritic restoration while the user is in `.vni`, because VNI
/// inserts accented characters straight into the app and leaves no ASCII buffer behind. `.english` stays a
/// strict pass-through: forcing it would silently break "Tắt dấu".
@Suite("Forced conversion across typing modes")
final class ForcedConversionTests {

    private let dbURL: URL
    private let store: LearningStore

    init() throws {
        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kodau-forced-conversion-\(UUID().uuidString).sqlite")
        store = try LearningStore(databaseURL: dbURL)
    }

    deinit {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbURL.path + suffix)
        }
    }

    private func makeCoordinator(_ config: AppConfig) -> SmartCoordinator {
        SmartCoordinator(store: store, config: config, geminiClient: GeminiClient())
    }

    @Test("VNI mode restores diacritics when the Smart engine is forced")
    func forcedConversionRestoresDiacriticsInVNI() {
        let coordinator = makeCoordinator(AppConfig(typingMode: .vni))

        let plain = coordinator.convertSync("duong", forceSmartEngine: false)
        #expect(plain.convertedText == "duong", "VNI mode only converts VNI-encoded tokens")

        let forced = coordinator.convertSync("duong", forceSmartEngine: true)
        #expect(forced.convertedText == "đường")
        #expect(forced.source != .passthrough)
    }

    @Test("English mode stays a strict pass-through even when forced")
    func forcedConversionNeverOverridesEnglish() {
        let coordinator = makeCoordinator(AppConfig(typingMode: .english))

        let forced = coordinator.convertSync("duong", forceSmartEngine: true)
        #expect(forced.convertedText == "duong")
        #expect(forced.source == .passthrough)
    }

    @Test("Smart mode is unaffected by the force flag")
    func forceFlagIsNoOpInSmartMode() {
        let coordinator = makeCoordinator(AppConfig(typingMode: .smart))

        let plain = coordinator.convertSync("duong")
        let forced = coordinator.convertSync("duong", forceSmartEngine: true)
        #expect(plain.convertedText == forced.convertedText)
        #expect(plain.source == forced.source)
    }

    @Test("Forced VNI conversion reaches Gemini when cloud refinement is enabled")
    func forcedConversionCallsGeminiInVNI() async {
        let coordinator = makeCoordinator(
            AppConfig(typingMode: .vni, brainStrategy: .cloudFirst, geminiAPIKey: "test-key")
        )
        coordinator.geminiRestoreOverride = { text, _, _, _ in
            ConversionResult(
                originalText: text,
                convertedText: "được",
                confidence: 0.92,
                source: .geminiAPI,
                vietnameseRatio: 1.0,
                alternatives: [],
                latencyMs: 1,
                tokenUsage: TokenUsage(model: "gemini-2.5-flash-lite", promptTokens: 10, outputTokens: 5)
            )
        }

        let result = await coordinator.convertSmart("duoc", forceSmartEngine: true)
        #expect(result.source == .geminiAPI)
        #expect(result.convertedText == "được")
    }

    @Test("Forced conversion in VNI mode does not run for English")
    func forcedSmartCallSkipsEnglish() async {
        let coordinator = makeCoordinator(
            AppConfig(typingMode: .english, brainStrategy: .cloudFirst, geminiAPIKey: "test-key")
        )
        coordinator.geminiRestoreOverride = { text, _, _, _ in
            Issue.record("Gemini must not be called in English mode")
            return ConversionResult(
                originalText: text,
                convertedText: "should-not-happen",
                confidence: 1.0,
                source: .geminiAPI,
                vietnameseRatio: 1.0,
                alternatives: [],
                latencyMs: 0
            )
        }

        let result = await coordinator.convertSmart("duong", forceSmartEngine: true)
        #expect(result.convertedText == "duong")
        #expect(result.source == .passthrough)
    }
}
