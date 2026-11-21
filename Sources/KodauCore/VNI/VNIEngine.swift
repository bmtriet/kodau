import Foundation

/// Result of processing a single incoming keystroke in VNI mode.
public struct VNIKeyResult: Equatable, Sendable {
    public let newWord: String
    public let didTransform: Bool
    public let backspacesNeeded: Int
    public let textToInsert: String

    public init(
        newWord: String,
        didTransform: Bool,
        backspacesNeeded: Int,
        textToInsert: String
    ) {
        self.newWord = newWord
        self.didTransform = didTransform
        self.backspacesNeeded = backspacesNeeded
        self.textToInsert = textToInsert
    }
}

/// Complete Vietnamese VNI typing engine with NFC normalization, double-tap undo,
/// proper `qu`/`gi` and diphthong/triphthong tone placement, and inline VNI detection.
public final class VNIEngine: Sendable {
    public let modernTonePlacement: Bool

    public init(modernTonePlacement: Bool = true) {
        self.modernTonePlacement = modernTonePlacement
    }

    // MARK: - Internal Vowel Representation

    private enum VowelShape: Int, Hashable, Sendable {
        case none = 0
        case circumflex = 1 // 6: â, ê, ô
        case horn = 2       // 7: ơ, ư
        case breve = 3      // 8: ă
    }

    private enum Tone: Int, Hashable, Sendable {
        case none = 0   // 0 / ngang
        case acute = 1  // 1: sắc
        case grave = 2  // 2: huyền
        case hook = 3   // 3: hỏi
        case tilde = 4  // 4: ngã
        case dot = 5    // 5: nặng
    }

    private struct VowelInfo: Hashable, Sendable {
        let base: Character      // lowercase ASCII: a, e, i, o, u, y
        let shape: VowelShape
        let tone: Tone
        let isUpper: Bool
    }

    private struct SyllableParts {
        let onsetEnd: Int     // exclusive index of onset (== vowelStart)
        let vowelStart: Int   // inclusive
        let vowelEnd: Int     // exclusive
        let hasCoda: Bool
    }

    // MARK: - Precomposed Unicode Tables (NFC)

    private static let vowelTables: (
        charToInfo: [Character: VowelInfo],
        infoToChar: [VowelInfo: Character]
    ) = {
        var c2i: [Character: VowelInfo] = [:]
        var i2c: [VowelInfo: Character] = [:]
        c2i.reserveCapacity(160)
        i2c.reserveCapacity(160)

        // (base, shape, lowercase 6 tones [none, acute, grave, hook, tilde, dot], uppercase 6 tones)
        let rows: [(Character, VowelShape, String, String)] = [
            ("a", .none,       "aáàảãạ", "AÁÀẢÃẠ"),
            ("a", .breve,      "ăắằẳẵặ", "ĂẮẰẲẴẶ"),
            ("a", .circumflex, "âấầẩẫậ", "ÂẤẦẨẪẬ"),
            ("e", .none,       "eéèẻẽẹ", "EÉÈẺẼẸ"),
            ("e", .circumflex, "êếềểễệ", "ÊẾỀỂỄỆ"),
            ("i", .none,       "iíìỉĩị", "IÍÌỈĨỊ"),
            ("o", .none,       "oóòỏõọ", "OÓÒỎÕỌ"),
            ("o", .circumflex, "ôốồổỗộ", "ÔỐỒỔỖỘ"),
            ("o", .horn,       "ơớờởỡợ", "ƠỚỜỞỠỢ"),
            ("u", .none,       "uúùủũụ", "UÚÙỦŨỤ"),
            ("u", .horn,       "ưứừửữự", "ƯỨỪỬỮỰ"),
            ("y", .none,       "yýỳỷỹỵ", "YÝỲỶỸỴ")
        ]

        let tones: [Tone] = [.none, .acute, .grave, .hook, .tilde, .dot]

        for (base, shape, lowerChars, upperChars) in rows {
            for (idx, ch) in lowerChars.enumerated() {
                let info = VowelInfo(base: base, shape: shape, tone: tones[idx], isUpper: false)
                c2i[ch] = info
                i2c[info] = ch
            }
            for (idx, ch) in upperChars.enumerated() {
                let info = VowelInfo(base: base, shape: shape, tone: tones[idx], isUpper: true)
                c2i[ch] = info
                i2c[info] = ch
            }
        }

        return (c2i, i2c)
    }()

    private static let validOnsets: Set<String> = [
        "", "b", "c", "ch", "d", "đ", "g", "gh", "gi", "h",
        "k", "kh", "l", "m", "n", "ng", "ngh", "nh", "p", "ph",
        "qu", "r", "s", "t", "th", "tr", "v", "x"
    ]

    private static let validCodas: Set<String> = [
        "", "c", "ch", "m", "n", "ng", "nh", "p", "t"
    ]

    private static let nonVietnameseASCII: Set<Character> = [
        "f", "j", "w", "z", "F", "J", "W", "Z"
    ]

    private static let vniDigits: Set<Character> = [
        "0", "1", "2", "3", "4", "5", "6", "7", "8", "9"
    ]

    // MARK: - Static Diacritic Utilities

    /// Strips all Vietnamese diacritics and đ/Đ -> d/D, returning ASCII string preserving case.
    public static func stripDiacritics(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let nfc = text.precomposedStringWithCanonicalMapping
        var result = String()
        result.reserveCapacity(nfc.count)

        let charToInfo = vowelTables.charToInfo
        for ch in nfc {
            if ch == "đ" {
                result.append("d")
            } else if ch == "Đ" {
                result.append("D")
            } else if let info = charToInfo[ch] {
                if info.isUpper {
                    result.append(uppercaseASCIIBase(info.base))
                } else {
                    result.append(info.base)
                }
            } else {
                result.append(ch)
            }
        }
        return result
    }

    /// Returns true if the string contains any Vietnamese diacritic character (including đ/Đ).
    public static func containsVietnameseDiacritics(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let nfc = text.precomposedStringWithCanonicalMapping
        let charToInfo = vowelTables.charToInfo

        for ch in nfc {
            if ch == "đ" || ch == "Đ" {
                return true
            }
            if let info = charToInfo[ch], (info.shape != .none || info.tone != .none) {
                return true
            }
        }
        return false
    }

    /// Normalizes Vietnamese tone placement on open `oa`, `oe`, `uy` syllables (preserving case and punctuation).
    /// - When `preferFirstVowel == true`: converts `hoà` -> `hòa`, `toà` -> `tòa`, `xoá` -> `xóa`, `khoẻ` -> `khỏe`, `thuý` -> `thúy`, `oà` -> `òa`.
    /// - When `preferFirstVowel == false`: converts `hòa` -> `hoà`, `khỏe` -> `khoẻ`, `thúy` -> `thuý`, `òa` -> `oà`.
    /// Closed syllables (`hoàn`, `toán`, `khoét`, `suýt`), triphthongs (`hoài`, `khuỷu`), and `qu` onset (`quý`) remain unchanged.
    public static func normalizeOaOeUyToneStyle(_ text: String, preferFirstVowel: Bool = true) -> String {
        guard !text.isEmpty else { return text }
        guard containsVietnameseDiacritics(text) else { return text }

        let nfc = text.precomposedStringWithCanonicalMapping
        let chars = Array(nfc)
        var result = String()
        result.reserveCapacity(nfc.count)

        var i = 0
        let count = chars.count
        while i < count {
            if chars[i].isLetter || chars[i].isNumber {
                let start = i
                while i < count && (chars[i].isLetter || chars[i].isNumber) {
                    i += 1
                }
                let tokenChars = Array(chars[start..<i])
                result.append(normalizeSingleWordOaOeUy(tokenChars, preferFirstVowel: preferFirstVowel))
            } else {
                result.append(chars[i])
                i += 1
            }
        }
        return result
    }

    private static func normalizeSingleWordOaOeUy(_ chars: [Character], preferFirstVowel: Bool) -> String {
        guard let parts = parseSyllableStatic(chars),
              !parts.hasCoda,
              parts.vowelEnd - parts.vowelStart == 2 else {
            return String(chars)
        }

        let idx0 = parts.vowelStart
        let idx1 = parts.vowelStart + 1
        guard let v0 = vowelTables.charToInfo[chars[idx0]],
              let v1 = vowelTables.charToInfo[chars[idx1]],
              v0.shape == .none,
              v1.shape == .none else {
            return String(chars)
        }

        let isTargetPair = (v0.base == "o" && (v1.base == "a" || v1.base == "e"))
            || (v0.base == "u" && v1.base == "y")
        guard isTargetPair else {
            return String(chars)
        }

        if preferFirstVowel {
            guard v0.tone == .none, v1.tone != .none else {
                return String(chars)
            }
            let newV0 = VowelInfo(base: v0.base, shape: .none, tone: v1.tone, isUpper: v0.isUpper)
            let newV1 = VowelInfo(base: v1.base, shape: .none, tone: .none, isUpper: v1.isUpper)
            guard let ch0 = vowelTables.infoToChar[newV0],
                  let ch1 = vowelTables.infoToChar[newV1] else {
                return String(chars)
            }
            var updated = chars
            updated[idx0] = ch0
            updated[idx1] = ch1
            return String(updated)
        } else {
            guard v0.tone != .none, v1.tone == .none else {
                return String(chars)
            }
            let newV0 = VowelInfo(base: v0.base, shape: .none, tone: .none, isUpper: v0.isUpper)
            let newV1 = VowelInfo(base: v1.base, shape: .none, tone: v0.tone, isUpper: v1.isUpper)
            guard let ch0 = vowelTables.infoToChar[newV0],
                  let ch1 = vowelTables.infoToChar[newV1] else {
                return String(chars)
            }
            var updated = chars
            updated[idx0] = ch0
            updated[idx1] = ch1
            return String(updated)
        }
    }

    private static func uppercaseASCIIBase(_ base: Character) -> Character {
        switch base {
        case "a": return "A"
        case "e": return "E"
        case "i": return "I"
        case "o": return "O"
        case "u": return "U"
        case "y": return "Y"
        default: return base
        }
    }

    // MARK: - Single Keystroke Processing

    /// Processes a single incoming VNI character appended to `currentWord`.
    public func processKey(currentWord: String, key: Character) -> VNIKeyResult {
        let normalizedOld = currentWord.precomposedStringWithCanonicalMapping
        let normalizedKey = String(key).precomposedStringWithCanonicalMapping
        let keyChar = normalizedKey.first ?? key

        // Non-digit key: append and optionally reposition tone / complete `ươ`.
        if !Self.vniDigits.contains(keyChar) {
            return processNonDigitKey(normalizedOld: normalizedOld, key: keyChar)
        }

        // Empty word or invalid buffer -> cannot apply VNI digit.
        guard !normalizedOld.isEmpty else {
            return passthrough(normalizedOld, key: keyChar)
        }

        let chars = Array(normalizedOld)

        // All existing characters must be valid Vietnamese letters (no digits, no symbols, no f/j/w/z).
        guard isEligibleVNIBuffer(chars) else {
            return passthrough(normalizedOld, key: keyChar)
        }

        // Key 9: stroke on leading d/D <-> đ/Đ (allowed even before any vowel is typed, e.g. "d" + "9" -> "đ").
        if keyChar == "9" {
            return applyStroke(chars: chars, normalizedOld: normalizedOld)
        }

        // For keys 0..8, parse syllable structure (requires at least one vowel).
        guard let parts = parseSyllable(chars) else {
            return passthrough(normalizedOld, key: keyChar)
        }

        switch keyChar {
        case "0":
            return applyToneRemoval(chars: chars, parts: parts, normalizedOld: normalizedOld)
        case "1":
            return applyTone(.acute, key: keyChar, chars: chars, parts: parts, normalizedOld: normalizedOld)
        case "2":
            return applyTone(.grave, key: keyChar, chars: chars, parts: parts, normalizedOld: normalizedOld)
        case "3":
            return applyTone(.hook, key: keyChar, chars: chars, parts: parts, normalizedOld: normalizedOld)
        case "4":
            return applyTone(.tilde, key: keyChar, chars: chars, parts: parts, normalizedOld: normalizedOld)
        case "5":
            return applyTone(.dot, key: keyChar, chars: chars, parts: parts, normalizedOld: normalizedOld)
        case "6":
            return applyCircumflex(chars: chars, parts: parts, normalizedOld: normalizedOld)
        case "7":
            return applyHorn(chars: chars, parts: parts, normalizedOld: normalizedOld)
        case "8":
            return applyBreve(chars: chars, parts: parts, normalizedOld: normalizedOld)
        default:
            return passthrough(normalizedOld, key: keyChar)
        }
    }

    // MARK: - Whole-Word VNI Conversion

    /// Converts an entire VNI-encoded token (e.g. "tie6ng1", "nguoi72", "d9uoc75", "Vie6t5") in one shot.
    public func convertWord(_ rawVNI: String) -> (converted: String, didConvert: Bool) {
        let normalized = rawVNI.precomposedStringWithCanonicalMapping
        guard !normalized.isEmpty else { return (rawVNI, false) }

        let rawChars = Array(normalized)

        // Must start with a letter (not a digit or symbol).
        guard let first = rawChars.first, isVietnameseLetter(first) else {
            return (rawVNI, false)
        }

        var hasDigit = false
        for ch in rawChars {
            if Self.vniDigits.contains(ch) {
                hasDigit = true
            } else if !isVietnameseLetter(ch) {
                return (rawVNI, false)
            }
        }
        guard hasDigit else { return (rawVNI, false) }

        var buffer = ""
        var anyTransformed = false
        for ch in rawChars {
            let res = processKey(currentWord: buffer, key: ch)
            if res.didTransform {
                anyTransformed = true
            }
            buffer = res.newWord
        }

        guard anyTransformed else {
            return (rawVNI, false)
        }

        // If any digit survived unprocessed (or was restored by double-tap undo), treat as non-VNI.
        if buffer.contains(where: { Self.vniDigits.contains($0) }) {
            return (rawVNI, false)
        }

        if buffer == normalized {
            return (rawVNI, false)
        }

        return (buffer, true)
    }

    // MARK: - Inline VNI Detection

    /// Detects if a raw or partially-converted token looks like an intentional inline VNI word
    /// (supports both pure ASCII VNI like `dau61`, `cuoi61`, `tu72`, `duoc759`, `tieng61`
    /// and partially-converted Vietnamese letters + trailing VNI digits like `tư2`, `dâu1`, `cuôi1`, `tiêng1`, `đươc5`).
    public func looksLikeInlineVNI(_ token: String) -> Bool {
        let normalized = token.precomposedStringWithCanonicalMapping
        guard !normalized.isEmpty else { return false }

        let chars = Array(normalized)
        guard let first = chars.first, isVietnameseLetter(first) else {
            return false
        }

        var lettersOnly = ""
        lettersOnly.reserveCapacity(chars.count)
        var digitCount = 0
        var hasExistingDiacritic = false

        for ch in chars {
            if isVietnameseLetter(ch) {
                let stripped = Self.stripDiacritics(String(ch))
                if stripped != String(ch) {
                    hasExistingDiacritic = true
                }
                lettersOnly.append(stripped)
            } else if ch >= "1" && ch <= "9" {
                digitCount += 1
            } else {
                // Reject '0' (not an inline diacritic marker) and any punctuation/symbol/non-Vietnamese letter.
                return false
            }
        }

        // Must contain 1..3 VNI digits (e.g. `ban5`, `tư2`, `tie6ng1`, `duoc759`).
        guard digitCount >= 1 && digitCount <= 3 else { return false }

        // `d9` / `D9` is the VNI stroke for `đ` / `Đ` and is typed BEFORE the rest of the syllable
        // (`D9a6u` -> `Đâu`), so it must convert immediately even though `d` alone is not a syllable yet.
        if normalized == "d9" || normalized == "D9" {
            return true
        }

        // Guard against short technical/common alphanumeric tokens like `a4`, `o2`, `i5`, `i7`, `u2`, `e2`.
        // Single-letter syllables are only accepted as inline VNI if they carry 2+ modifiers (e.g., `o73` -> `ở`)
        // or already contain a Vietnamese diacritic (e.g., `ơ3` -> `ở`).
        if lettersOnly.count < 2 {
            if !(lettersOnly.count == 1 && (digitCount >= 2 || hasExistingDiacritic)) {
                return false
            }
        }

        // Stripped letters must form a phonologically valid Vietnamese syllable.
        guard VietnamesePhonology.isValidVietnameseSyllable(lettersOnly) else {
            return false
        }

        let (converted, didConvert) = convertWord(normalized)
        guard didConvert else { return false }

        return Self.containsVietnameseDiacritics(converted)
    }

    // MARK: - Non-Digit Continuation (Tone Repositioning & `ư` + `o` -> `ươ`)

    private func processNonDigitKey(normalizedOld: String, key: Character) -> VNIKeyResult {
        guard !normalizedOld.isEmpty, isVietnameseLetter(key) else {
            return passthrough(normalizedOld, key: key)
        }

        let oldChars = Array(normalizedOld)
        guard isEligibleVNIBuffer(oldChars) else {
            return passthrough(normalizedOld, key: key)
        }

        var nextChars = oldChars
        nextChars.append(key)

        guard let parts = parseSyllable(nextChars) else {
            return passthrough(normalizedOld, key: key)
        }

        var modified = false

        // Auto-complete `ư` + `o` -> `ươ` if user typed horn on `u` before `o`.
        if parts.vowelEnd - parts.vowelStart >= 2 {
            for idx in parts.vowelStart..<(parts.vowelEnd - 1) {
                if let uInfo = Self.vowelTables.charToInfo[nextChars[idx]],
                   let oInfo = Self.vowelTables.charToInfo[nextChars[idx + 1]],
                   uInfo.base == "u", uInfo.shape == .horn,
                   oInfo.base == "o", oInfo.shape == .none {
                    let newOInfo = VowelInfo(base: "o", shape: .horn, tone: oInfo.tone, isUpper: oInfo.isUpper)
                    if let newO = Self.vowelTables.infoToChar[newOInfo] {
                        nextChars[idx + 1] = newO
                        modified = true
                    }
                }
            }
        }

        // If `gi` had a tone on `i` before a following vowel arrived (e.g. `gí` + `a` -> `giá`), move tone into nucleus.
        if parts.onsetEnd == 2,
           let iInfo = Self.vowelTables.charToInfo[nextChars[1]],
           iInfo.base == "i", iInfo.tone != .none {
            let plainI = VowelInfo(base: "i", shape: .none, tone: .none, isUpper: iInfo.isUpper)
            if let ch = Self.vowelTables.infoToChar[plainI] {
                nextChars[1] = ch
                if applyToneInPlace(iInfo.tone, chars: &nextChars, parts: parts) {
                    modified = true
                }
            }
        } else if repositionExistingToneIfNeeded(chars: &nextChars, parts: parts) {
            modified = true
        }

        let candidate = String(nextChars)
        if modified && candidate != normalizedOld + String(key) {
            return diffResult(oldWord: normalizedOld, newWord: candidate, didTransform: true)
        }
        return passthrough(normalizedOld, key: key)
    }

    // MARK: - VNI Transformations

    private func applyStroke(chars: [Character], normalizedOld: String) -> VNIKeyResult {
        guard let first = chars.first else {
            return passthrough(normalizedOld, key: "9")
        }

        // Allow leading d/D/đ/Đ alone, or as valid onset of a syllable/prefix.
        if chars.count > 1 && parseSyllable(chars) == nil {
            // Also check if buffer is just consonants? Only `d` can be onset with no other consonant attached.
            return passthrough(normalizedOld, key: "9")
        }

        var updated = chars
        switch first {
        case "d":
            updated[0] = "đ"
            return diffResult(oldWord: normalizedOld, newWord: String(updated), didTransform: true)
        case "D":
            updated[0] = "Đ"
            return diffResult(oldWord: normalizedOld, newWord: String(updated), didTransform: true)
        case "đ":
            // Double-tap undo
            updated[0] = "d"
            updated.append("9")
            return diffResult(oldWord: normalizedOld, newWord: String(updated), didTransform: true)
        case "Đ":
            // Double-tap undo
            updated[0] = "D"
            updated.append("9")
            return diffResult(oldWord: normalizedOld, newWord: String(updated), didTransform: true)
        default:
            return passthrough(normalizedOld, key: "9")
        }
    }

    private func applyCircumflex(chars: [Character], parts: SyllableParts, normalizedOld: String) -> VNIKeyResult {
        // Find target vowel among a, e, o in the vowel nucleus.
        var targetIndex: Int?
        for idx in parts.vowelStart..<parts.vowelEnd {
            if let info = Self.vowelTables.charToInfo[chars[idx]],
               info.base == "a" || info.base == "e" || info.base == "o" {
                // Prefer one that already has circumflex (for undo), otherwise last eligible vowel.
                if info.shape == .circumflex {
                    targetIndex = idx
                    break
                }
                targetIndex = idx
            }
        }

        guard let idx = targetIndex, let info = Self.vowelTables.charToInfo[chars[idx]] else {
            return passthrough(normalizedOld, key: "6")
        }

        var updated = chars
        if info.shape == .circumflex {
            // Double-tap undo
            let reverted = VowelInfo(base: info.base, shape: .none, tone: info.tone, isUpper: info.isUpper)
            if let ch = Self.vowelTables.infoToChar[reverted] {
                updated[idx] = ch
            }
            updated.append("6")
            return diffResult(oldWord: normalizedOld, newWord: String(updated), didTransform: true)
        }

        let nextInfo = VowelInfo(base: info.base, shape: .circumflex, tone: info.tone, isUpper: info.isUpper)
        guard let nextChar = Self.vowelTables.infoToChar[nextInfo] else {
            return passthrough(normalizedOld, key: "6")
        }
        updated[idx] = nextChar
        repositionExistingToneIfNeeded(chars: &updated, parts: parts)
        return diffResult(oldWord: normalizedOld, newWord: String(updated), didTransform: true)
    }

    private func applyBreve(chars: [Character], parts: SyllableParts, normalizedOld: String) -> VNIKeyResult {
        var targetIndex: Int?
        for idx in parts.vowelStart..<parts.vowelEnd {
            if let info = Self.vowelTables.charToInfo[chars[idx]], info.base == "a" {
                targetIndex = idx
                if info.shape == .breve { break }
            }
        }

        guard let idx = targetIndex, let info = Self.vowelTables.charToInfo[chars[idx]] else {
            return passthrough(normalizedOld, key: "8")
        }

        var updated = chars
        if info.shape == .breve {
            // Double-tap undo
            let reverted = VowelInfo(base: "a", shape: .none, tone: info.tone, isUpper: info.isUpper)
            if let ch = Self.vowelTables.infoToChar[reverted] {
                updated[idx] = ch
            }
            updated.append("8")
            return diffResult(oldWord: normalizedOld, newWord: String(updated), didTransform: true)
        }

        let nextInfo = VowelInfo(base: "a", shape: .breve, tone: info.tone, isUpper: info.isUpper)
        guard let nextChar = Self.vowelTables.infoToChar[nextInfo] else {
            return passthrough(normalizedOld, key: "8")
        }
        updated[idx] = nextChar
        repositionExistingToneIfNeeded(chars: &updated, parts: parts)
        return diffResult(oldWord: normalizedOld, newWord: String(updated), didTransform: true)
    }

    private func applyHorn(chars: [Character], parts: SyllableParts, normalizedOld: String) -> VNIKeyResult {
        // Case A: Compound `uo` -> `ươ` (automatically horns both `u` and `o`).
        if parts.vowelEnd - parts.vowelStart >= 2 {
            for idx in parts.vowelStart..<(parts.vowelEnd - 1) {
                if let uInfo = Self.vowelTables.charToInfo[chars[idx]],
                   let oInfo = Self.vowelTables.charToInfo[chars[idx + 1]],
                   uInfo.base == "u", oInfo.base == "o" {
                    var updated = chars
                    if uInfo.shape == .horn && oInfo.shape == .horn {
                        // Double-tap undo on compound `ươ` -> `uo7`
                        let revU = VowelInfo(base: "u", shape: .none, tone: uInfo.tone, isUpper: uInfo.isUpper)
                        let revO = VowelInfo(base: "o", shape: .none, tone: oInfo.tone, isUpper: oInfo.isUpper)
                        if let chU = Self.vowelTables.infoToChar[revU],
                           let chO = Self.vowelTables.infoToChar[revO] {
                            updated[idx] = chU
                            updated[idx + 1] = chO
                            updated.append("7")
                            return diffResult(oldWord: normalizedOld, newWord: String(updated), didTransform: true)
                        }
                    } else {
                        let newU = VowelInfo(base: "u", shape: .horn, tone: uInfo.tone, isUpper: uInfo.isUpper)
                        let newO = VowelInfo(base: "o", shape: .horn, tone: oInfo.tone, isUpper: oInfo.isUpper)
                        if let chU = Self.vowelTables.infoToChar[newU],
                           let chO = Self.vowelTables.infoToChar[newO] {
                            updated[idx] = chU
                            updated[idx + 1] = chO
                            repositionExistingToneIfNeeded(chars: &updated, parts: parts)
                            return diffResult(oldWord: normalizedOld, newWord: String(updated), didTransform: true)
                        }
                    }
                }
            }
        }

        // Case B: Single `o` or `u` (for `uu` like `ưu`/`cứu`/`lưu`, horn applies to the first `u`).
        var targetIndex: Int?
        for idx in parts.vowelStart..<parts.vowelEnd {
            if let info = Self.vowelTables.charToInfo[chars[idx]],
               info.base == "o" || info.base == "u" {
                if info.shape == .horn {
                    targetIndex = idx
                    break
                }
                if targetIndex == nil {
                    targetIndex = idx
                } else if info.base == "o" {
                    targetIndex = idx
                }
            }
        }

        guard let idx = targetIndex, let info = Self.vowelTables.charToInfo[chars[idx]] else {
            return passthrough(normalizedOld, key: "7")
        }

        var updated = chars
        if info.shape == .horn {
            // Double-tap undo
            let reverted = VowelInfo(base: info.base, shape: .none, tone: info.tone, isUpper: info.isUpper)
            if let ch = Self.vowelTables.infoToChar[reverted] {
                updated[idx] = ch
            }
            updated.append("7")
            return diffResult(oldWord: normalizedOld, newWord: String(updated), didTransform: true)
        }

        let nextInfo = VowelInfo(base: info.base, shape: .horn, tone: info.tone, isUpper: info.isUpper)
        guard let nextChar = Self.vowelTables.infoToChar[nextInfo] else {
            return passthrough(normalizedOld, key: "7")
        }
        updated[idx] = nextChar
        repositionExistingToneIfNeeded(chars: &updated, parts: parts)
        return diffResult(oldWord: normalizedOld, newWord: String(updated), didTransform: true)
    }

    private func applyToneRemoval(chars: [Character], parts: SyllableParts, normalizedOld: String) -> VNIKeyResult {
        var updated = chars
        var removed = false
        for idx in parts.vowelStart..<parts.vowelEnd {
            if let info = Self.vowelTables.charToInfo[updated[idx]], info.tone != .none {
                let plain = VowelInfo(base: info.base, shape: info.shape, tone: .none, isUpper: info.isUpper)
                if let ch = Self.vowelTables.infoToChar[plain] {
                    updated[idx] = ch
                    removed = true
                }
            }
        }
        guard removed else {
            return passthrough(normalizedOld, key: "0")
        }
        return diffResult(oldWord: normalizedOld, newWord: String(updated), didTransform: true)
    }

    private func applyTone(
        _ tone: Tone,
        key: Character,
        chars: [Character],
        parts: SyllableParts,
        normalizedOld: String
    ) -> VNIKeyResult {
        var existingTone: Tone = .none
        var existingToneIdx: Int?

        for idx in parts.vowelStart..<parts.vowelEnd {
            if let info = Self.vowelTables.charToInfo[chars[idx]], info.tone != .none {
                existingTone = info.tone
                existingToneIdx = idx
                break
            }
        }

        var updated = chars

        // Double-tap undo: pressing the exact same tone key reverts the tone and appends the literal digit.
        if existingTone == tone, let toneIdx = existingToneIdx,
           let info = Self.vowelTables.charToInfo[updated[toneIdx]] {
            let plain = VowelInfo(base: info.base, shape: info.shape, tone: .none, isUpper: info.isUpper)
            if let ch = Self.vowelTables.infoToChar[plain] {
                updated[toneIdx] = ch
            }
            updated.append(key)
            return diffResult(oldWord: normalizedOld, newWord: String(updated), didTransform: true)
        }

        // Clear any previous tone before applying the new tone at the canonical target vowel.
        if let oldIdx = existingToneIdx, let oldInfo = Self.vowelTables.charToInfo[updated[oldIdx]] {
            let plain = VowelInfo(base: oldInfo.base, shape: oldInfo.shape, tone: .none, isUpper: oldInfo.isUpper)
            if let ch = Self.vowelTables.infoToChar[plain] {
                updated[oldIdx] = ch
            }
        }

        guard applyToneInPlace(tone, chars: &updated, parts: parts) else {
            return passthrough(normalizedOld, key: key)
        }

        return diffResult(oldWord: normalizedOld, newWord: String(updated), didTransform: true)
    }

    @discardableResult
    private func applyToneInPlace(_ tone: Tone, chars: inout [Character], parts: SyllableParts) -> Bool {
        let vowelInfos = (parts.vowelStart..<parts.vowelEnd).compactMap { Self.vowelTables.charToInfo[chars[$0]] }
        guard vowelInfos.count == (parts.vowelEnd - parts.vowelStart), !vowelInfos.isEmpty else {
            return false
        }

        let relativeIdx = toneTargetIndex(vowels: vowelInfos, hasCoda: parts.hasCoda)
        let targetIdx = parts.vowelStart + relativeIdx
        let current = vowelInfos[relativeIdx]
        let nextInfo = VowelInfo(base: current.base, shape: current.shape, tone: tone, isUpper: current.isUpper)
        guard let nextChar = Self.vowelTables.infoToChar[nextInfo] else {
            return false
        }
        chars[targetIdx] = nextChar
        return true
    }

    @discardableResult
    private func repositionExistingToneIfNeeded(chars: inout [Character], parts: SyllableParts) -> Bool {
        var existingTone: Tone = .none
        var existingIdx: Int?
        for idx in parts.vowelStart..<parts.vowelEnd {
            if let info = Self.vowelTables.charToInfo[chars[idx]], info.tone != .none {
                existingTone = info.tone
                existingIdx = idx
                break
            }
        }
        guard existingTone != .none, let oldIdx = existingIdx else {
            return false
        }

        let vowelInfos = (parts.vowelStart..<parts.vowelEnd).compactMap { Self.vowelTables.charToInfo[chars[$0]] }
        guard vowelInfos.count == (parts.vowelEnd - parts.vowelStart) else { return false }

        let targetIdx = parts.vowelStart + toneTargetIndex(vowels: vowelInfos, hasCoda: parts.hasCoda)
        guard targetIdx != oldIdx else { return false }

        let oldInfo = vowelInfos[oldIdx - parts.vowelStart]
        let targetInfo = vowelInfos[targetIdx - parts.vowelStart]

        let clearedOld = VowelInfo(base: oldInfo.base, shape: oldInfo.shape, tone: .none, isUpper: oldInfo.isUpper)
        let tonedTarget = VowelInfo(base: targetInfo.base, shape: targetInfo.shape, tone: existingTone, isUpper: targetInfo.isUpper)

        guard let newOldChar = Self.vowelTables.infoToChar[clearedOld],
              let newTargetChar = Self.vowelTables.infoToChar[tonedTarget] else {
            return false
        }

        chars[oldIdx] = newOldChar
        chars[targetIdx] = newTargetChar
        return true
    }

    /// Selects the relative index within `vowels` (after `qu`/`gi` onset) that receives the Vietnamese tone mark.
    private func toneTargetIndex(vowels: [VowelInfo], hasCoda: Bool) -> Int {
        if vowels.count == 1 {
            return 0
        }

        // Rule 1: If `ơ` or `ê` is present (covers `ươ`, `ươi`, `ươu`, `iê`, `yê`, `iêu`, `yêu`, `uyê`, `ơi`, `êu`),
        // it always takes the tone mark.
        if let idx = vowels.firstIndex(where: { ($0.base == "o" && $0.shape == .horn) || ($0.base == "e" && $0.shape == .circumflex) }) {
            return idx
        }

        // Rule 2: Any other shaped vowel (`â`, `ô`, `ă`, `ư`) takes the tone mark.
        if let idx = vowels.firstIndex(where: { $0.shape != .none }) {
            return idx
        }

        // Rule 3: Triphthongs without shaped vowels (e.g. `oai`, `oay`, `oeo`, `uya`, `uyu`) -> middle vowel.
        if vowels.count >= 3 {
            return 1
        }

        // Rule 4: Two plain vowels.
        if hasCoda {
            // Closed syllable (`toán`, `hoàn`, `khoét`, `suýt`, `tuần`, `việt`) -> second vowel.
            return 1
        }

        let pair = String([vowels[0].base, vowels[1].base])
        switch pair {
        case "oa", "oe", "uy":
            // `modernTonePlacement == true` -> `hòa`, `khỏe`, `thủy` (first vowel).
            // `modernTonePlacement == false` -> `hoà`, `khoẻ`, `thuỷ` (second vowel).
            return modernTonePlacement ? 0 : 1
        case "ie", "ye", "uo":
            // Intermediate nuclei awaiting circumflex/horn (`tié` -> `tiế`, `nguò` -> `ngườ`).
            return 1
        default:
            // Open diphthongs (`mái`, `báo`, `sáu`, `máy`, `kéo`, `mía`, `chịu`, `nói`, `múa`, `túi`) -> first vowel.
            return 0
        }
    }

    // MARK: - Syllable Parsing & Validation Helpers

    private func isVietnameseLetter(_ ch: Character) -> Bool {
        if ch == "đ" || ch == "Đ" { return true }
        if Self.vowelTables.charToInfo[ch] != nil { return true }
        if ch.isASCII && ch.isLetter && !Self.nonVietnameseASCII.contains(ch) {
            return true
        }
        return false
    }

    private func isEligibleVNIBuffer(_ chars: [Character]) -> Bool {
        guard !chars.isEmpty && chars.count <= 8 else { return false }
        for ch in chars {
            if !isVietnameseLetter(ch) {
                return false
            }
        }
        return true
    }

    private func parseSyllable(_ chars: [Character]) -> SyllableParts? {
        Self.parseSyllableStatic(chars)
    }

    private static func parseSyllableStatic(_ chars: [Character]) -> SyllableParts? {
        let count = chars.count
        guard count > 0 else { return nil }

        let charToInfo = vowelTables.charToInfo
        var onsetEnd = 0

        // Handle special `qu` and `gi` onsets when followed by another vowel.
        if count >= 3 {
            let c0Lower = String(chars[0]).lowercased()
            let c1Info = charToInfo[chars[1]]
            let c2IsVowel = charToInfo[chars[2]] != nil

            if c0Lower == "q", let u = c1Info, u.base == "u", u.shape == .none, u.tone == .none, c2IsVowel {
                onsetEnd = 2
            } else if c0Lower == "g", let i = c1Info, i.base == "i", c2IsVowel {
                onsetEnd = 2
            }
        }

        if onsetEnd == 0 {
            while onsetEnd < count && charToInfo[chars[onsetEnd]] == nil {
                onsetEnd += 1
            }
        }

        let onset = String(chars[0..<onsetEnd]).lowercased()
        guard Self.validOnsets.contains(onset) else { return nil }

        // Contiguous vowel nucleus.
        var vowelEnd = onsetEnd
        while vowelEnd < count && charToInfo[chars[vowelEnd]] != nil {
            vowelEnd += 1
        }

        let vowelCount = vowelEnd - onsetEnd
        guard vowelCount >= 1 && vowelCount <= 3 else { return nil }

        // Remaining characters must be a valid Vietnamese coda (no further vowels).
        for idx in vowelEnd..<count {
            if charToInfo[chars[idx]] != nil {
                return nil
            }
        }

        let coda = String(chars[vowelEnd..<count]).lowercased()
        guard Self.validCodas.contains(coda) else { return nil }

        return SyllableParts(
            onsetEnd: onsetEnd,
            vowelStart: onsetEnd,
            vowelEnd: vowelEnd,
            hasCoda: !coda.isEmpty
        )
    }

    // MARK: - Diff Construction

    private func passthrough(_ normalizedOld: String, key: Character) -> VNIKeyResult {
        let s = String(key)
        return VNIKeyResult(
            newWord: normalizedOld + s,
            didTransform: false,
            backspacesNeeded: 0,
            textToInsert: s
        )
    }

    private func diffResult(oldWord: String, newWord: String, didTransform: Bool) -> VNIKeyResult {
        let oldChars = Array(oldWord)
        let newChars = Array(newWord)

        var prefixLen = 0
        let minLen = min(oldChars.count, newChars.count)
        while prefixLen < minLen && oldChars[prefixLen] == newChars[prefixLen] {
            prefixLen += 1
        }

        let backspaces = oldChars.count - prefixLen
        let insert = String(newChars[prefixLen...])

        return VNIKeyResult(
            newWord: newWord,
            didTransform: didTransform,
            backspacesNeeded: backspaces,
            textToInsert: insert
        )
    }
}
