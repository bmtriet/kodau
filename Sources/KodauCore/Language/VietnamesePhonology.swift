import Foundation

/// Single-token language hint without surrounding sentence context.
public enum TokenLanguageHint: Equatable, Sendable {
    case definiteEnglishOrCode
    case likelyEnglish
    case ambiguous
    case likelyVietnamese
    case definiteVietnamese
}

/// Strict Vietnamese syllable phonology, orthographic validation, code/technical token detection,
/// and casing preservation utilities.
public enum VietnamesePhonology {

    private static let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]
    private static let nonVietnameseLetters: Set<Character> = ["f", "j", "w", "z", "F", "J", "W", "Z"]

    private static let validOnsets: Set<String> = [
        "", "b", "c", "ch", "d", "g", "gh", "gi", "h",
        "k", "kh", "l", "m", "n", "ng", "ngh", "nh", "p", "ph",
        "qu", "r", "s", "t", "th", "tr", "v", "x"
    ]

    private static let validCodas: Set<String> = [
        "", "c", "ch", "m", "n", "ng", "nh", "p", "t"
    ]

    /// Valid open-syllable vowel nuclei (coda == "").
    private static let validOpenNuclei: Set<String> = [
        // Monophthongs
        "a", "e", "i", "o", "u", "y",
        // Diphthongs
        "ai", "ao", "au", "ay",
        "eo", "eu",
        "ia", "iu",
        "oa", "oe", "oi",
        "ua", "ue", "ui", "uo", "uu", "uy",
        // Triphthongs
        "ieu", "oai", "oao", "oay", "oeo",
        "uay", "uoi", "uou", "uya", "uyu", "yeu"
    ]

    /// Valid closed-syllable (nucleus -> allowed non-empty codas).
    private static let validClosedCodasByNucleus: [String: Set<String>] = [
        "a":   ["c", "ch", "m", "n", "ng", "nh", "p", "t"],
        "e":   ["c", "ch", "m", "n", "ng", "nh", "p", "t"],
        "i":   ["ch", "m", "n", "nh", "p", "t"],
        "o":   ["c", "m", "n", "ng", "p", "t"],
        "u":   ["c", "m", "n", "ng", "p", "t"],
        "y":   ["ch", "n", "nh", "p", "t"],
        "ie":  ["c", "m", "n", "ng", "p", "t"],
        "ye":  ["m", "n", "ng", "t"],
        "oa":  ["c", "ch", "m", "n", "ng", "nh", "p", "t"],
        "oe":  ["n", "t"],
        "oo":  ["c", "ng"],
        "ua":  ["n", "ng", "t"],
        "ue":  ["ch", "n", "nh", "t"],
        "uo":  ["c", "m", "n", "ng", "p", "t"],
        "uy":  ["ch", "n", "nh", "p", "t"],
        "uye": ["n", "t"]
    ]

    /// Known ALLCAPS technical, developer, and business acronyms (>= 2 chars).
    private static let knownAcronyms: Set<String> = [
        "AI", "API", "ASCII", "ASAP", "AWS", "B2B", "B2C", "BI", "CD", "CDN",
        "CEO", "CFO", "CI", "CLI", "CMS", "COO", "CORS", "CPU", "CRM", "CRUD",
        "CSRF", "CSS", "CSV", "CTO", "DB", "DDOS", "DEV", "DL", "DNS", "DOM",
        "DRY", "ENV", "EOF", "ERP", "ETA", "FAQ", "FTP", "FYI", "GCP", "GIF",
        "GPU", "GRPC", "GUI", "HDMI", "HR", "HTML", "HTTP", "HTTPS", "HUD",
        "ID", "IDE", "IME", "INI", "IO", "IOS", "IP", "IT", "JPEG", "JPG",
        "JS", "JSON", "JSX", "JWT", "KPI", "LAN", "LDAP", "LLM", "MAC", "MD",
        "ML", "MVP", "MVC", "MVVM", "NAT", "NLP", "NPM", "OAUTH", "OK", "OKR",
        "ORM", "OS", "OTP", "PDF", "PHP", "PID", "PIN", "PM", "PNG", "PR",
        "PROD", "QA", "QR", "RAM", "REST", "RFC", "ROI", "RPC", "RSS", "SDK",
        "SEO", "SIM", "SLA", "SMS", "SMTP", "SQL", "SQLITE", "SSH", "SSL",
        "SSO", "SVG", "TBD", "TCP", "TLS", "TOML", "TS", "TSX", "TTL", "TTY",
        "UDP", "UI", "URI", "URL", "USB", "UTF", "UUID", "UX", "VM", "VNI",
        "VPN", "WAN", "WASM", "XML", "XSS", "YAML", "YML"
    ]

    private static let codeSymbols: Set<Character> = [
        "_", "$", "#", "%", "^", "&", "*", "+", "=", "<", ">",
        "{", "}", "[", "]", "|", "`", "~", "\\", "/"
    ]

    // MARK: - Vietnamese Syllable Phonology

    /// Returns true if the ASCII lowercased token is a phonologically valid Vietnamese syllable
    /// (valid onset, vowel nucleus, coda, and Vietnamese orthographic rules).
    public static func isValidVietnameseSyllable(_ word: String) -> Bool {
        guard !word.isEmpty else { return false }

        // Strip Vietnamese diacritics if present, then verify pure ASCII a-z without f/j/w/z.
        let stripped = VNIEngine.stripDiacritics(word).lowercased()
        guard stripped.count >= 1 && stripped.count <= 7 else { return false }

        let chars = Array(stripped)
        for ch in chars {
            guard ch.isASCII, ch >= "a" && ch <= "z" else { return false }
            if ch == "f" || ch == "j" || ch == "w" || ch == "z" { return false }
        }

        // Parse onset (with special handling for `qu` and `gi`).
        var onsetEnd = 0
        if chars.count >= 3 {
            if chars[0] == "q" && chars[1] == "u" && vowels.contains(chars[2]) {
                onsetEnd = 2
            } else if chars[0] == "g" && chars[1] == "i" && vowels.contains(chars[2]) {
                onsetEnd = 2
            }
        }

        if onsetEnd == 0 {
            while onsetEnd < chars.count && !vowels.contains(chars[onsetEnd]) {
                onsetEnd += 1
            }
        }

        let onset = String(chars[0..<onsetEnd])
        guard validOnsets.contains(onset) else { return false }

        // Parse contiguous vowel nucleus.
        var vowelEnd = onsetEnd
        while vowelEnd < chars.count && vowels.contains(chars[vowelEnd]) {
            vowelEnd += 1
        }
        guard vowelEnd > onsetEnd && (vowelEnd - onsetEnd) <= 3 else { return false }

        // Remaining characters must all be consonants forming a valid coda.
        for idx in vowelEnd..<chars.count {
            if vowels.contains(chars[idx]) {
                return false
            }
        }

        let nucleus = String(chars[onsetEnd..<vowelEnd])
        let coda = String(chars[vowelEnd..<chars.count])
        guard validCodas.contains(coda) else { return false }

        // Vietnamese orthographic onset-nucleus rules.
        guard let firstVowel = nucleus.first else { return false }
        switch onset {
        case "k":
            guard firstVowel == "e" || firstVowel == "i" || firstVowel == "y" else { return false }
        case "c":
            guard firstVowel == "a" || firstVowel == "o" || firstVowel == "u" else { return false }
        case "gh", "ngh":
            guard firstVowel == "e" || firstVowel == "i" else { return false }
        case "g":
            // `g` alone precedes a/o/u, or `i` in `gi`/`gin`/`git` (no vowel after `i`).
            guard firstVowel == "a" || firstVowel == "o" || firstVowel == "u" || firstVowel == "i" else { return false }
        case "ng":
            guard firstVowel == "a" || firstVowel == "o" || firstVowel == "u" else { return false }
        case "qu":
            // `qu` cannot be followed by `u` directly (e.g. `quu`).
            guard firstVowel != "u" else { return false }
        case "gi":
            // `gi` onset cannot be followed by another `i` directly (`gii`).
            guard firstVowel != "i" else { return false }
        default:
            break
        }

        // Validate rhyme (nucleus + coda).
        if coda.isEmpty {
            return validOpenNuclei.contains(nucleus)
        } else {
            guard let allowedCodas = validClosedCodasByNucleus[nucleus] else {
                return false
            }
            // Nucleus `y` with a coda only occurs after `qu` (e.g. `quỳnh`, `quýt`, `quỵch`).
            if nucleus == "y" && onset != "qu" {
                return false
            }
            return allowedCodas.contains(coda)
        }
    }

    // MARK: - Code & Technical Token Detection

    /// Returns true if the token is a code identifier, URL, email, file path, number,
    /// camelCase, snake_case, ALLCAPS acronym (>= 2 chars), or contains non-Vietnamese letters (f, j, w, z).
    public static func isCodeOrTechnicalToken(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }

        let lower = token.lowercased()

        // URLs & protocols
        if lower.contains("://")
            || lower.hasPrefix("www.")
            || lower.hasPrefix("http:")
            || lower.hasPrefix("https:")
            || lower.hasPrefix("mailto:")
            || lower.hasPrefix("file:") {
            return true
        }

        // Emails
        if let atIdx = token.firstIndex(of: "@"),
           atIdx > token.startIndex,
           token.index(after: atIdx) < token.endIndex {
            return true
        }

        // File paths & CLI flags
        if token.hasPrefix("~/") || token.hasPrefix("./") || token.hasPrefix("../") || token.hasPrefix("--") {
            return true
        }

        let chars = Array(token)
        var hasDigit = false
        var hasLower = false
        var hasUpper = false
        var hasInternalUpper = false
        var allASCIIUpper = true
        var letterCount = 0

        for (idx, ch) in chars.enumerated() {
            // Digits (numbers, versions, technical IDs like 2026, v1.2.3, utf8)
            if ch.isNumber {
                hasDigit = true
            }

            // Code symbols (snake_case, paths, operators, brackets)
            if codeSymbols.contains(ch) {
                return true
            }

            // Dot-separated identifiers or versions (e.g. foo.bar, v1.2.3, App.swift)
            if ch == "." && idx > 0 && idx < chars.count - 1 {
                let prev = chars[idx - 1]
                let next = chars[idx + 1]
                if (prev.isLetter || prev.isNumber) && (next.isLetter || next.isNumber) {
                    return true
                }
            }

            // Hyphenated technical identifiers (e.g. kebab-case, utf-8)
            if ch == "-" && idx > 0 && idx < chars.count - 1 {
                let prev = chars[idx - 1]
                let next = chars[idx + 1]
                if (prev.isLetter || prev.isNumber) && (next.isLetter || next.isNumber) {
                    return true
                }
            }

            // Non-Vietnamese Latin letters (f, j, w, z)
            if nonVietnameseLetters.contains(ch) {
                return true
            }

            if ch.isLetter {
                letterCount += 1
                if ch.isUppercase {
                    hasUpper = true
                    if idx > 0 {
                        hasInternalUpper = true
                    }
                    if !ch.isASCII {
                        allASCIIUpper = false
                    }
                } else {
                    hasLower = true
                    allASCIIUpper = false
                }
            } else {
                allASCIIUpper = false
            }
        }

        // Any numeric token or token containing digits
        if hasDigit {
            return true
        }

        // camelCase / PascalCase / mixed internal uppercase (e.g. camelCase, macOS, UIViewController, GitHub)
        if hasLower && hasInternalUpper {
            return true
        }

        // ALLCAPS acronyms (>= 2 ASCII uppercase letters, e.g. API, PR, SQL, URL, UI, OS, LLM, AI)
        // Preserve ALLCAPS Vietnamese words (e.g. TIENG, VIET, KHONG, DAU) by excluding valid Vietnamese
        // syllables unless they are recognized technical acronyms.
        if allASCIIUpper && letterCount >= 2 && hasUpper && !hasLower {
            if knownAcronyms.contains(token) {
                return true
            }
            if !isValidVietnameseSyllable(lower) {
                return true
            }
        }

        return false
    }

    // MARK: - Single-Token Classification

    /// Classifies a single token given no surrounding context.
    public static func classifyToken(_ token: String) -> TokenLanguageHint {
        guard !token.isEmpty else { return .ambiguous }

        // Already has Vietnamese diacritics -> definite Vietnamese.
        if VNIEngine.containsVietnameseDiacritics(token) {
            return .definiteVietnamese
        }

        // Code / URL / email / number / camelCase / snake_case / acronym / f,j,w,z -> definite English or code.
        if isCodeOrTechnicalToken(token) {
            return .definiteEnglishOrCode
        }

        let lower = token.lowercased()
        let isValidVN = isValidVietnameseSyllable(lower)
        let inEnglish = SeedLexicon.englishWords.contains(lower)
        let inAmbiguous = SeedLexicon.ambiguousEnViWords.contains(lower)
        let inVietnamese = SeedLexicon.vietnameseUnigrams[lower] != nil

        if !isValidVN {
            return inEnglish ? .definiteEnglishOrCode : .likelyEnglish
        }

        if inAmbiguous || (inEnglish && inVietnamese) {
            return .ambiguous
        }

        if inEnglish {
            return .likelyEnglish
        }

        if inVietnamese {
            return .likelyVietnamese
        }

        return .likelyVietnamese
    }

    // MARK: - Casing Preservation

    /// Applies casing of `template` (lowercase, Capitalized, ALLCAPS) to `target`.
    public static func preserveCasing(from template: String, to target: String) -> String {
        guard !template.isEmpty, !target.isEmpty else { return target }

        let letters = template.filter(\.isLetter)
        guard !letters.isEmpty else { return target }

        if letters.allSatisfy(\.isUppercase) {
            return target.uppercased()
        }

        if let firstLetter = letters.first, firstLetter.isUppercase {
            let rest = letters.dropFirst()
            if rest.allSatisfy(\.isLowercase) {
                let firstChar = target.prefix(1).uppercased()
                let tail = target.dropFirst().lowercased()
                return firstChar + tail
            }
        }

        return target.lowercased()
    }
}
