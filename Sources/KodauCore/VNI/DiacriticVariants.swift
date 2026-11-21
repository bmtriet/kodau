import Foundation

/// Generates every valid Vietnamese diacritic form of one ASCII syllable.
///
/// `ban` → `bán`, `bàn`, `bản`, `bạn`, `bần`, `bẩn`, `bận`, `bắn`, `bằn`, …; `dau` also yields the `đ` onset
/// (`đâu`, `đấu`). Every produced surface strips back to the same ASCII base with `VNIEngine.stripDiacritics`.
///
/// Used by the “Xem thêm” (`⌥6`) popup expansion when the wanted word is not among the ≤5 quick candidates.
public enum DiacriticVariants {

    // MARK: - Public API

    /// All valid forms of `base`, ranked: the word's current candidates first (in their order), then by
    /// `SeedLexicon` unigram weight, then the rest in a stable generation order.
    ///
    /// - Parameters:
    ///   - base: ASCII syllable the forms must strip back to (case-insensitive, diacritics ignored).
    ///   - rawCasing: the word exactly as the user typed it, so casing (`Ban`, `BAN`) is preserved.
    ///   - currentCandidates: the popup's existing candidates — always kept first, and the only way the plain
    ///     ASCII form itself (e.g. `ban`) can appear.
    ///   - preferFirstVowel: modern tone placement (`hòa` vs `hoà`), from `AppConfig.modernTonePlacement`.
    ///   - limit: hard cap on the returned list.
    public static func all(
        for base: String,
        rawCasing: String,
        currentCandidates: [String] = [],
        preferFirstVowel: Bool = true,
        limit: Int = 40
    ) -> [String] {
        let normalizedBase = VNIEngine.stripDiacritics(base).lowercased()
        guard !normalizedBase.isEmpty, limit > 0 else { return [] }

        let casingTemplate = rawCasing.isEmpty ? normalizedBase : rawCasing
        var results: [String] = []
        var seen = Set<String>()
        results.reserveCapacity(min(limit, 40))
        seen.reserveCapacity(min(limit, 40))

        // 1. Existing candidates keep their order (and their original casing).
        for candidate in currentCandidates {
            guard VNIEngine.stripDiacritics(candidate).lowercased() == normalizedBase else { continue }
            if seen.insert(candidate.lowercased()).inserted {
                results.append(candidate)
            }
            if results.count >= limit { return results }
        }

        // 2. Every generated form, ranked by seed weight then generation order.
        let generated = generatedSurfaces(for: normalizedBase, preferFirstVowel: preferFirstVowel)
        guard !generated.isEmpty else { return results }

        let weights = seedWeights(for: normalizedBase)
        var ranked: [(index: Int, surface: String, weight: Double)] = []
        ranked.reserveCapacity(generated.count)
        for (index, surface) in generated.enumerated() {
            guard !seen.contains(surface.lowercased()) else { continue }
            ranked.append((index, surface, weights[surface.lowercased()] ?? 0))
        }
        ranked.sort { lhs, rhs in
            lhs.weight == rhs.weight ? lhs.index < rhs.index : lhs.weight > rhs.weight
        }

        for item in ranked {
            let cased = VietnamesePhonology.preserveCasing(from: casingTemplate, to: item.surface)
            if seen.insert(cased.lowercased()).inserted {
                results.append(cased)
            }
            if results.count >= limit { break }
        }
        return results
    }

    // MARK: - Generation

    private static func generatedSurfaces(for base: String, preferFirstVowel: Bool) -> [String] {
        guard let parts = parse(base) else { return [] }
        let engine = VNIEngine(modernTonePlacement: preferFirstVowel)
        let onsets = parts.onset == "d" ? ["d", "đ"] : [parts.onset]
        let nuclei = shapeOptions(for: parts.nucleus)
        guard !nuclei.isEmpty else { return [] }

        var surfaces: [String] = []
        for onset in onsets {
            for nucleus in nuclei {
                guard isValidRhyme(nucleus: nucleus, coda: parts.coda) else { continue }
                let untoned = onset + nucleus + parts.coda
                guard VietnamesePhonology.isValidVietnameseSyllable(untoned) else { continue }

                // A shaped (or `đ`) untoned form is a real word on its own (`băn`, `đau`); the plain ASCII
                // form is only ever surfaced if the popup already offered it as a candidate.
                if VNIEngine.containsVietnameseDiacritics(untoned) {
                    surfaces.append(untoned)
                }

                for digit in ["1", "2", "3", "4", "5"] {
                    let result = engine.processKey(currentWord: untoned, key: Character(digit))
                    guard result.didTransform else { continue }
                    surfaces.append(result.newWord)
                }
            }
        }
        return surfaces
    }

    private static func shapeOptions(for nucleus: String) -> [String] {
        var results = [""]
        for ch in nucleus {
            let options: [Character]
            switch ch {
            case "a": options = ["a", "ă", "â"]
            case "e": options = ["e", "ê"]
            case "o": options = ["o", "ô", "ơ"]
            case "u": options = ["u", "ư"]
            default: options = [ch]
            }
            results = results.flatMap { prefix in options.map { prefix + String($0) } }
        }
        return results
    }

    private static func seedWeights(for base: String) -> [String: Double] {
        guard let entries = SeedLexicon.vietnameseUnigrams[base] else { return [:] }
        var weights: [String: Double] = [:]
        weights.reserveCapacity(entries.count)
        for entry in entries {
            let key = entry.surface.lowercased()
            weights[key] = max(weights[key] ?? 0, entry.weight)
        }
        return weights
    }

    // MARK: - Syllable Parsing & Rhyme Validity

    private struct Syllable {
        let onset: String
        let nucleus: String
        let coda: String
    }

    private static let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]

    private static let validOnsets: Set<String> = [
        "", "b", "c", "ch", "d", "đ", "g", "gh", "gi", "h",
        "k", "kh", "l", "m", "n", "ng", "ngh", "nh", "p", "ph",
        "qu", "r", "s", "t", "th", "tr", "v", "x"
    ]

    private static let validCodas: Set<String> = ["", "c", "ch", "m", "n", "ng", "nh", "p", "t"]

    /// Valid open-syllable nuclei *with* their vowel shapes (`â`/`ă`/`ê`/`ô`/`ơ`/`ư`).
    private static let openNuclei: Set<String> = [
        "a", "e", "ê", "i", "o", "ô", "ơ", "u", "ư", "y",
        "ai", "ao", "au", "ay", "âu", "ây", "eo", "êu",
        "ia", "iu", "oa", "oe", "oi", "ôi", "ơi",
        "ua", "uê", "ui", "uơ", "uy",
        "ưa", "ưi", "ưu",
        "iêu", "yêu", "oai", "oao", "oay", "oeo",
        "uây", "uôi", "uya", "uyu", "ươi", "ươu"
    ]

    /// Valid codas per shaped nucleus for closed syllables. Anything absent is not a Vietnamese rhyme
    /// (e.g. `ơc`, `ănh`, `ưoc`), so it is never generated.
    private static let closedCodas: [String: Set<String>] = [
        "a": ["c", "ch", "m", "n", "ng", "nh", "p", "t"],
        "ă": ["c", "m", "n", "ng", "p", "t"],
        "â": ["c", "m", "n", "ng", "p", "t"],
        "e": ["c", "ch", "m", "n", "ng", "nh", "p", "t"],
        "ê": ["c", "ch", "m", "n", "nh", "p", "t"],
        "i": ["ch", "m", "n", "nh", "p", "t"],
        "o": ["c", "m", "n", "ng", "p", "t"],
        "ô": ["c", "m", "n", "ng", "p", "t"],
        "ơ": ["m", "n", "p", "t"],
        "u": ["c", "m", "n", "ng", "p", "t"],
        "ư": ["c", "m", "n", "ng", "p", "t"],
        "oa": ["c", "ch", "m", "n", "ng", "nh", "p", "t"],
        "oă": ["c", "n", "ng", "t"],
        "oe": ["n", "t"],
        "oo": ["c", "ng"],
        "ua": ["n", "ng", "t"],
        "uâ": ["n", "t"],
        "uê": ["ch", "nh"],
        "uô": ["c", "m", "n", "ng", "p", "t"],
        "uy": ["ch", "n", "nh", "p", "t"],
        "ươ": ["c", "m", "n", "ng", "p", "t"],
        "iê": ["c", "m", "n", "ng", "p", "t"],
        "yê": ["m", "n", "p", "t"],
        "uyê": ["n", "t"]
    ]

    private static func isValidRhyme(nucleus: String, coda: String) -> Bool {
        if coda.isEmpty { return openNuclei.contains(nucleus) }
        guard let codas = closedCodas[nucleus] else { return false }
        return codas.contains(coda)
    }

    private static func parse(_ base: String) -> Syllable? {
        let chars = Array(base)
        guard !chars.isEmpty else { return nil }

        var onsetEnd = 0
        if chars.count >= 3 {
            if chars[0] == "q", chars[1] == "u", vowels.contains(chars[2]) {
                onsetEnd = 2
            } else if chars[0] == "g", chars[1] == "i", vowels.contains(chars[2]) {
                onsetEnd = 2
            }
        }
        if onsetEnd == 0 {
            while onsetEnd < chars.count && !vowels.contains(chars[onsetEnd]) { onsetEnd += 1 }
        }

        let onset = String(chars[0..<onsetEnd])
        guard validOnsets.contains(onset) else { return nil }

        var vowelEnd = onsetEnd
        while vowelEnd < chars.count && vowels.contains(chars[vowelEnd]) { vowelEnd += 1 }
        guard vowelEnd > onsetEnd, (vowelEnd - onsetEnd) <= 3 else { return nil }

        let nucleus = String(chars[onsetEnd..<vowelEnd])
        let coda = String(chars[vowelEnd...])
        guard validCodas.contains(coda) else { return nil }

        return Syllable(onset: onset, nucleus: nucleus, coda: coda)
    }
}
