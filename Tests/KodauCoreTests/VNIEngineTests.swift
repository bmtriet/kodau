import Foundation
import Testing
@testable import KodauCore

@Suite("VNIEngine Tests")
struct VNIEngineTests {

    private let engine = VNIEngine(modernTonePlacement: true)

    // MARK: - Tones (1..5, 0 remove)

    @Test("Basic VNI tones 1-5")
    func testBasicTones() {
        let cases: [(String, String)] = [
            ("a1", "á"),
            ("a2", "à"),
            ("a3", "ả"),
            ("a4", "ã"),
            ("a5", "ạ"),
            ("e1", "é"),
            ("i2", "ì"),
            ("o3", "ỏ"),
            ("u4", "ũ"),
            ("y5", "ỵ"),
            ("ban5", "bạn"),
            ("ban1", "bán"),
            ("ban2", "bàn"),
            ("ban3", "bản"),
            ("ban4", "bãn")
        ]

        for (raw, expected) in cases {
            let result = engine.convertWord(raw)
            #expect(result.didConvert, "Expected '\(raw)' to convert")
            #expect(result.converted == expected, "Input '\(raw)' produced '\(result.converted)', expected '\(expected)'")
        }
    }

    @Test("Tone removal with 0")
    func testToneRemovalWithZero() {
        let step1 = engine.processKey(currentWord: "a", key: "1")
        #expect(step1.didTransform)
        #expect(step1.newWord == "á")

        let step2 = engine.processKey(currentWord: step1.newWord, key: "0")
        #expect(step2.didTransform)
        #expect(step2.newWord == "a")

        let wordResult = engine.convertWord("ban50")
        #expect(wordResult.converted == "ban")
    }

    @Test("Tone replacement")
    func testToneReplacement() {
        let step1 = engine.processKey(currentWord: "ma", key: "1")
        #expect(step1.newWord == "má")

        let step2 = engine.processKey(currentWord: step1.newWord, key: "2")
        #expect(step2.didTransform)
        #expect(step2.newWord == "mà")
    }

    // MARK: - Modifiers (6, 7, 8, 9)

    @Test("Circumflex modifier 6")
    func testCircumflexModifier6() {
        let cases: [(String, String)] = [
            ("a6", "â"),
            ("e6", "ê"),
            ("o6", "ô"),
            ("vie6t5", "việt"),
            ("tie6ng1", "tiếng"),
            ("kho6ng", "không"),
            ("co6ng", "công"),
            ("ca6n2", "cần")
        ]

        for (raw, expected) in cases {
            let result = engine.convertWord(raw)
            #expect(result.didConvert, "Expected '\(raw)' to convert")
            #expect(result.converted == expected, "Input '\(raw)' produced '\(result.converted)', expected '\(expected)'")
        }
    }

    @Test("Horn modifier 7 including uo -> ươ")
    func testHornModifier7IncludingCompoundUO() {
        let cases: [(String, String)] = [
            ("o7", "ơ"),
            ("u7", "ư"),
            ("mo7", "mơ"),
            ("tu7", "tư"),
            ("uo7", "ươ"),
            ("nuo7c1", "nước"),
            ("nguo7i2", "người"),
            ("d9uo7c5", "được"),
            ("truo7ng2", "trường")
        ]

        for (raw, expected) in cases {
            let result = engine.convertWord(raw)
            #expect(result.didConvert, "Expected '\(raw)' to convert")
            #expect(result.converted == expected, "Input '\(raw)' produced '\(result.converted)', expected '\(expected)'")
        }
    }

    @Test("Breve modifier 8")
    func testBreveModifier8() {
        let cases: [(String, String)] = [
            ("a8", "ă"),
            ("a8n", "ăn"),
            ("na8ng1", "nắng"),
            ("ba8ng2", "bằng"),
            ("tra8ng", "trăng")
        ]

        for (raw, expected) in cases {
            let result = engine.convertWord(raw)
            #expect(result.didConvert, "Expected '\(raw)' to convert")
            #expect(result.converted == expected, "Input '\(raw)' produced '\(result.converted)', expected '\(expected)'")
        }
    }

    @Test("Stroke modifier 9 (d -> đ)")
    func testStrokeModifier9() {
        let cases: [(String, String)] = [
            ("d9", "đ"),
            ("d9i", "đi"),
            ("d9a4", "đã"),
            ("d9ang", "đang"),
            ("d9e6n1", "đến")
        ]

        for (raw, expected) in cases {
            let result = engine.convertWord(raw)
            #expect(result.didConvert, "Expected '\(raw)' to convert")
            #expect(result.converted == expected, "Input '\(raw)' produced '\(result.converted)', expected '\(expected)'")
        }
    }

    // MARK: - Uppercase and TitleCase

    @Test("Uppercase and TitleCase preservation")
    func testUppercaseAndTitleCase() {
        let cases: [(String, String)] = [
            ("Vie6t5", "Việt"),
            ("D9", "Đ"),
            ("D9i", "Đi"),
            ("TIE6NG1", "TIẾNG"),
            ("VIE6T5", "VIỆT"),
            ("D9UO7C5", "ĐƯỢC"),
            ("KHO6NG", "KHÔNG"),
            ("A8N", "ĂN")
        ]

        for (raw, expected) in cases {
            let result = engine.convertWord(raw)
            #expect(result.didConvert, "Expected '\(raw)' to convert")
            #expect(result.converted == expected, "Input '\(raw)' produced '\(result.converted)', expected '\(expected)'")
        }
    }

    // MARK: - Double-Tap Undo & Keystroke ProcessResult

    @Test("Double-tap undo restores ASCII and digit")
    func testDoubleTapUndo() {
        let first = engine.processKey(currentWord: "a", key: "1")
        #expect(first.didTransform)
        #expect(first.newWord == "á")
        #expect(first.backspacesNeeded == 1)
        #expect(first.textToInsert == "á")

        let second = engine.processKey(currentWord: first.newWord, key: "1")
        #expect(second.didTransform)
        #expect(second.newWord == "a1")
        #expect(second.backspacesNeeded == 1)
        #expect(second.textToInsert == "a1")
    }

    @Test("Incremental keystroke processing")
    func testProcessKeyIncrementalWordTyping() {
        var word = ""
        for ch in "vie6t5" {
            let res = engine.processKey(currentWord: word, key: ch)
            word = res.newWord
        }
        #expect(word == "việt")
    }

    // MARK: - qu / gi Tone Placement & Modern vs Classic

    @Test("qu and gi tone placement")
    func testQuAndGiTonePlacement() {
        #expect(engine.convertWord("qua1").converted == "quá")
        #expect(engine.convertWord("qua2").converted == "quà")
        #expect(engine.convertWord("gia1").converted == "giá")
        #expect(engine.convertWord("gia2").converted == "già")
        #expect(engine.convertWord("gio72").converted == "giờ")
        #expect(engine.convertWord("quye6n2").converted == "quyền")
    }

    @Test("Modern vs classic tone placement")
    func testModernVsClassicTonePlacement() {
        let modernEngine = VNIEngine(modernTonePlacement: true)
        let classicEngine = VNIEngine(modernTonePlacement: false)

        #expect(modernEngine.convertWord("hoa2").converted == "hòa")
        #expect(classicEngine.convertWord("hoa2").converted == "hoà")
    }

    // MARK: - Non-Vietnamese Numbers & Technical Tokens

    @Test("Non-Vietnamese numbers remain unchanged")
    func testNonVietnameseNumbersRemainUnchanged() {
        let nonVNI = ["2026", "v1", "mp3", "utf8", "12345", "h2", "3d"]

        for token in nonVNI {
            let result = engine.convertWord(token)
            #expect(!result.didConvert, "Token '\(token)' should not convert as VNI")
            #expect(result.converted == token, "Token '\(token)' should stay unchanged")
        }
    }

    // MARK: - Inline VNI Detection

    @Test("looksLikeInlineVNI detection")
    func testLooksLikeInlineVNI() {
        let positive = ["tie6ng1", "vie6t5", "ban5", "kho6ng", "d9uo7c5", "nguo7i2", "Vie6t5"]
        for token in positive {
            #expect(engine.looksLikeInlineVNI(token), "Expected '\(token)' to look like inline VNI")
        }

        let negative = ["2026", "v1", "mp3", "utf8", "hello", "viet", "swift", "", "v2.0"]
        for token in negative {
            #expect(!engine.looksLikeInlineVNI(token), "Expected '\(token)' NOT to look like inline VNI")
        }
    }

    // MARK: - Static Diacritic Utilities

    @Test("stripDiacritics removes all Vietnamese marks")
    func testStripDiacritics() {
        #expect(VNIEngine.stripDiacritics("Tiếng Việt không dấu") == "Tieng Viet khong dau")
        #expect(VNIEngine.stripDiacritics("ĐƯỜNG PHỐ HÀ NỘI") == "DUONG PHO HA NOI")
        #expect(VNIEngine.stripDiacritics("đặc biệt 123!") == "dac biet 123!")
        #expect(VNIEngine.stripDiacritics("Hello Swift macOS") == "Hello Swift macOS")
    }

    @Test("containsVietnameseDiacritics detects diacritics accurately")
    func testContainsVietnameseDiacritics() {
        #expect(VNIEngine.containsVietnameseDiacritics("Tiếng Việt"))
        #expect(VNIEngine.containsVietnameseDiacritics("đi"))
        #expect(VNIEngine.containsVietnameseDiacritics("Đ"))
        #expect(VNIEngine.containsVietnameseDiacritics("hòa"))

        #expect(!VNIEngine.containsVietnameseDiacritics("tieng viet khong dau"))
        #expect(!VNIEngine.containsVietnameseDiacritics("Hello World 2026"))
        #expect(!VNIEngine.containsVietnameseDiacritics(""))
    }

    // MARK: - End-of-Word Multi-Digit VNI & Partially Converted Inline VNI

    @Test("End-of-word VNI works in all key orders")
    func testEndOfWordVNIAllKeyOrders() {
        let cases: [(String, String)] = [
            ("dau61", "dấu"),
            ("dau16", "dấu"),
            ("cuoi61", "cuối"),
            ("cuoi16", "cuối"),
            ("tu72", "từ"),
            ("tu27", "từ"),
            ("tieng61", "tiếng"),
            ("tieng16", "tiếng"),
            ("duoc759", "được"),
            ("duoc975", "được"),
            ("duoc579", "được"),
            ("hoa2", "hòa"),
            ("oa2", "òa")
        ]

        for (raw, expected) in cases {
            let result = engine.convertWord(raw)
            #expect(result.didConvert, "Expected '\(raw)' to convert")
            #expect(result.converted == expected, "Input '\(raw)' produced '\(result.converted)', expected '\(expected)'")

            // Verify incremental processKey typing produces the exact same result
            var buffer = ""
            for ch in raw {
                buffer = engine.processKey(currentWord: buffer, key: ch).newWord
            }
            #expect(buffer == expected, "Incremental '\(raw)' produced '\(buffer)', expected '\(expected)'")
        }
    }

    @Test("Partially converted Vietnamese letters with trailing VNI digits")
    func testPartiallyConvertedInlineVNI() {
        let positive: [(String, String)] = [
            ("tư2", "từ"),
            ("dâu1", "dấu"),
            ("cuôi1", "cuối"),
            ("tiêng1", "tiếng"),
            ("đươc5", "được"),
            ("tu72", "từ"),
            ("dau61", "dấu"),
            ("cuoi61", "cuối"),
            ("duoc759", "được"),
            ("tieng61", "tiếng")
        ]

        for (token, expected) in positive {
            #expect(engine.looksLikeInlineVNI(token), "Expected looksLikeInlineVNI('\(token)') == true")
            let result = engine.convertWord(token)
            #expect(result.didConvert, "Expected convertWord('\(token)') to convert")
            #expect(result.converted == expected, "Expected '\(token)' -> '\(expected)', got '\(result.converted)'")
        }

        let technicalRejected = ["2026", "v1", "mp3", "h2o", "3d", "utf8", "gpt4", "i18n", "base64", "a4", "o2", "i5", "i7"]
        for token in technicalRejected {
            #expect(!engine.looksLikeInlineVNI(token), "Expected technical token '\(token)' to be rejected")
        }
    }

    // MARK: - oa / oe / uy Tone Style Normalizer

    @Test("normalizeOaOeUyToneStyle enforces open syllable tone placement without breaking closed syllables")
    func testNormalizeOaOeUyToneStyle() {
        #expect(
            VNIEngine.normalizeOaOeUyToneStyle("hoà bình, khoẻ mạnh, hoàn thành", preferFirstVowel: true)
                == "hòa bình, khỏe mạnh, hoàn thành"
        )
        #expect(
            VNIEngine.normalizeOaOeUyToneStyle("toà nhà, xoá bỏ, thuý kiều, oà khóc", preferFirstVowel: true)
                == "tòa nhà, xóa bỏ, thúy kiều, òa khóc"
        )
        #expect(
            VNIEngine.normalizeOaOeUyToneStyle("Hoà, TOÀ, XOÁ, Khoẻ, THUÝ, Oà", preferFirstVowel: true)
                == "Hòa, TÒA, XÓA, Khỏe, THÚY, Òa"
        )
        // Closed syllables, triphthongs, and `qu` onset must remain untouched
        #expect(
            VNIEngine.normalizeOaOeUyToneStyle("hoàn toán khoét suýt quý hoài khuỷu", preferFirstVowel: true)
                == "hoàn toán khoét suýt quý hoài khuỷu"
        )
        // Classic placement when preferFirstVowel == false
        #expect(
            VNIEngine.normalizeOaOeUyToneStyle("hòa bình, khỏe mạnh, thúy, hoàn thành", preferFirstVowel: false)
                == "hoà bình, khoẻ mạnh, thuý, hoàn thành"
        )
    }

    @Test("d9 / D9 stroke is recognized as inline VNI so Smart Mode types đ / Đ immediately")
    func strokeIsInlineVNI() {
        let vni = VNIEngine(modernTonePlacement: true)
        #expect(vni.looksLikeInlineVNI("d9"))
        #expect(vni.looksLikeInlineVNI("D9"))
        #expect(vni.processKey(currentWord: "D", key: "9").newWord == "Đ")
        #expect(vni.processKey(currentWord: "d", key: "9").newWord == "đ")
        // Short technical tokens stay untouched
        #expect(!vni.looksLikeInlineVNI("a4"))
        #expect(!vni.looksLikeInlineVNI("i5"))
    }
}
