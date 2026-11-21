import Foundation
import Testing
@testable import KodauCore

@Suite("LocalDiacriticEngine and Phonology Tests")
final class LocalEngineTests {

    private let tempDBURL: URL
    private let store: LearningStore
    private let engine: LocalDiacriticEngine

    init() throws {
        tempDBURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kodau_local_engine_tests_\(UUID().uuidString).sqlite")
        store = try LearningStore(databaseURL: tempDBURL)
        engine = LocalDiacriticEngine(store: store)
    }

    deinit {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: tempDBURL.path + suffix)
        }
    }

    // MARK: - Pure Vietnamese Không Dấu Restoration

    @Test("Pure Vietnamese không dấu restoration")
    func testPureVietnameseRestoration() {
        let r1 = engine.convert("hom nay toi di lam", precedingContext: "")
        #expect(r1.convertedText == "hôm nay tôi đi làm")
        #expect(r1.didChange)
        #expect(r1.source.isOffline)
        #expect(r1.vietnameseRatio > 0.5)

        let r2 = engine.convert("tieng viet khong dau", precedingContext: "")
        #expect(r2.convertedText == "tiếng việt không dấu")
        #expect(r2.didChange)
        #expect(r2.source.isOffline)

        let r3 = engine.convert("cam on ban rat nhieu", precedingContext: "")
        #expect(r3.convertedText == "cảm ơn bạn rất nhiều")
        #expect(r3.didChange)
    }

    // MARK: - Pure English Preservation

    @Test("Pure English sentences are preserved untouched")
    func testPureEnglishPreservation() {
        let englishSentence = "I want to build a macOS app with Swift"
        let result = engine.convert(englishSentence, precedingContext: "")

        #expect(result.convertedText == englishSentence)
        #expect(!result.didChange)
        #expect(result.source == .localEnglish)
        #expect(result.vietnameseRatio <= 0.25)

        let secondEnglish = "Please review the pull request and merge it"
        let r2 = engine.convert(secondEnglish, precedingContext: "")
        #expect(r2.convertedText == secondEnglish)
        #expect(!r2.didChange)
        #expect(r2.source == .localEnglish)
    }

    // MARK: - Mixed Vietnamese-English Code-Switching

    @Test("Mixed Vietnamese-English code-switching preserves English tokens")
    func testMixedVietnameseEnglishCodeSwitching() {
        let input = "hom nay toi review code va fix bug cho app nay"
        let result = engine.convert(input, precedingContext: "")

        #expect(result.didChange)
        #expect(result.source.isOffline)
        #expect(VNIEngine.containsVietnameseDiacritics(result.convertedText))

        let tokens = result.convertedText.split(separator: " ").map(String.init)
        #expect(tokens.count == 11, "Token count should be preserved: \(result.convertedText)")

        // English technical words must stay untouched
        #expect(tokens[3] == "review")
        #expect(tokens[4] == "code")
        #expect(tokens[6] == "fix")
        #expect(tokens[7] == "bug")
        #expect(tokens[9] == "app")

        // Core Vietnamese words must receive diacritics
        #expect(tokens[0] == "hôm")
        #expect(tokens[2] == "tôi")
        #expect(tokens[5] == "và")
        #expect(tokens[10] == "này")
    }

    @Test("Mixed sentence with technical terms preserves deploy/API/server")
    func testMixedTechnicalTermsPreserved() {
        let input = "toi dang deploy API len server"
        let result = engine.convert(input, precedingContext: "")

        let tokens = result.convertedText.split(separator: " ").map(String.init)
        #expect(tokens.count == 6)
        #expect(tokens[0] == "tôi")
        #expect(tokens[1] == "đang")
        #expect(tokens[2] == "deploy")
        #expect(tokens[3] == "API")
        #expect(tokens[4] == "lên")
        #expect(tokens[5] == "server")
    }

    // MARK: - Punctuation & Casing Preservation

    @Test("Punctuation and casing preservation")
    func testPunctuationAndCasingPreservation() {
        let titleCase = engine.convert("Hom nay, toi di lam!", precedingContext: "")
        #expect(titleCase.convertedText == "Hôm nay, tôi đi làm!")

        let upperCase = engine.convert("TIENG VIET KHONG DAU?", precedingContext: "")
        #expect(upperCase.convertedText == "TIẾNG VIỆT KHÔNG DẤU?")

        let parenthesized = engine.convert("(cam on ban!)", precedingContext: "")
        #expect(parenthesized.convertedText == "(cảm ơn bạn!)")
    }

    // MARK: - VietnamesePhonology

    @Test("Valid and invalid Vietnamese syllables")
    func testValidAndInvalidVietnameseSyllables() {
        let validSyllables = [
            "viet", "tieng", "nguoi", "khong", "truong",
            "nghieng", "qua", "gia", "an", "em", "hom", "nay"
        ]
        for word in validSyllables {
            #expect(
                VietnamesePhonology.isValidVietnameseSyllable(word),
                "Expected '\(word)' to be a valid Vietnamese syllable"
            )
        }

        let invalidSyllables = [
            "review", "swift", "script", "debug", "build",
            "world", "xcode", "flutter", "zoom", "fix", "jazz", "app"
        ]
        for word in invalidSyllables {
            #expect(
                !VietnamesePhonology.isValidVietnameseSyllable(word),
                "Expected '\(word)' NOT to be a valid Vietnamese syllable"
            )
        }
    }

    @Test("Code and technical token detection")
    func testCodeOrTechnicalTokenDetection() {
        let codeTokens = [
            "camelCase",
            "snake_case",
            "macOS",
            "foo.bar",
            "https://example.com",
            "v1.2.3",
            "UIViewController"
        ]
        for token in codeTokens {
            #expect(
                VietnamesePhonology.isCodeOrTechnicalToken(token),
                "Expected '\(token)' to be detected as code/technical token"
            )
        }

        let plainWords = ["hom", "nay", "tieng", "viet", "hello"]
        for word in plainWords {
            #expect(
                !VietnamesePhonology.isCodeOrTechnicalToken(word),
                "Expected '\(word)' NOT to be detected as code/technical token"
            )
        }
    }

    @Test("Token language classification")
    func testTokenClassification() {
        #expect(VietnamesePhonology.classifyToken("camelCase") == .definiteEnglishOrCode)
        #expect(VietnamesePhonology.classifyToken("snake_case") == .definiteEnglishOrCode)
        #expect(VietnamesePhonology.classifyToken("macOS") == .definiteEnglishOrCode)
        #expect(VietnamesePhonology.classifyToken("https://apple.com") == .definiteEnglishOrCode)

        let swiftHint = VietnamesePhonology.classifyToken("swift")
        #expect(
            swiftHint == .definiteEnglishOrCode || swiftHint == .likelyEnglish,
            "Expected 'swift' to classify as English/code, got \(swiftHint)"
        )

        #expect(VietnamesePhonology.classifyToken("tiếng") == .definiteVietnamese)

        let khongHint = VietnamesePhonology.classifyToken("khong")
        #expect(
            khongHint == .likelyVietnamese || khongHint == .definiteVietnamese,
            "Expected 'khong' to classify as Vietnamese, got \(khongHint)"
        )
    }

    @Test("Casing preservation helper")
    func testPreserveCasing() {
        #expect(VietnamesePhonology.preserveCasing(from: "hom", to: "hôm") == "hôm")
        #expect(VietnamesePhonology.preserveCasing(from: "Hom", to: "hôm") == "Hôm")
        #expect(VietnamesePhonology.preserveCasing(from: "HOM", to: "hôm") == "HÔM")
        #expect(VietnamesePhonology.preserveCasing(from: "Di", to: "đi") == "Đi")
        #expect(VietnamesePhonology.preserveCasing(from: "DI", to: "đi") == "ĐI")
        #expect(VietnamesePhonology.preserveCasing(from: "Viet", to: "việt") == "Việt")
    }
}
