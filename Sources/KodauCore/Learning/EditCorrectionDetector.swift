import Foundation

/// A word found next to the text cursor, plus up to two preceding words of the same sentence (oldest first).
public struct WordAtCursor: Equatable, Sendable {
    public let word: String
    public let prevWords: [String]
    /// The word right after it in the same sentence (right-hand context), if any.
    public let nextWord: String?

    public init(word: String, prevWords: [String] = [], nextWord: String? = nil) {
        self.word = word
        self.prevWords = prevWords
        self.nextWord = nextWord
    }
}

/// A learning opportunity detected when the user goes back and re-edits text Kodau already restored,
/// e.g. `bán → bạn`. Shown in a toast so the user can confirm before Kodau learns it.
public struct EditCorrectionCandidate: Equatable, Sendable {
    /// ASCII base form without diacritics, lowercased (e.g. `ban`).
    public let baseWord: String
    /// The word that was on screen before the user's edit (e.g. `bán`).
    public let originalSurface: String
    /// The word the user changed it to (e.g. `bạn`).
    public let correctedSurface: String
    /// Preceding context words (closest to the word last), lowercased.
    public let prev1: String?
    public let prev2: String?
    /// The word after the corrected one (right-hand context), lowercased.
    public let next1: String?

    public init(
        baseWord: String,
        originalSurface: String,
        correctedSurface: String,
        prev1: String?,
        prev2: String?,
        next1: String? = nil
    ) {
        self.baseWord = baseWord
        self.originalSurface = originalSurface
        self.correctedSurface = correctedSurface
        self.prev1 = prev1
        self.prev2 = prev2
        self.next1 = next1
    }

    /// Context words before the corrected word, e.g. `"tôi muốn"`.
    public var contextBefore: String {
        [prev2, prev1].compactMap { $0 }.joined(separator: " ")
    }
}

/// Pure helpers that decide whether a post-commit edit is a correction worth learning.
public enum EditCorrectionDetector {

    /// Words longer than this are ignored (URLs, code identifiers, pasted blobs).
    public static let maxWordLength = 24

    /// Finds the word touching `cursorUTF16Offset` inside `text`.
    ///
    /// Preference order: the word ending at / containing the cursor; then (when `skipOneSeparatorLeft`)
    /// the word just before a single space or punctuation mark left of the cursor; finally the word starting at the cursor.
    public static func wordAtCursor(
        in text: String,
        cursorUTF16Offset: Int,
        skipOneSeparatorLeft: Bool = true
    ) -> WordAtCursor? {
        let chars = Array(text)
        guard !chars.isEmpty else { return nil }

        // Map UTF-16 offset to a Character index (clamped).
        var charIndex = 0
        var utf16Count = 0
        while charIndex < chars.count {
            let next = utf16Count + String(chars[charIndex]).utf16.count
            if next > cursorUTF16Offset { break }
            utf16Count = next
            charIndex += 1
        }
        let cursor = min(max(0, charIndex), chars.count)

        var anchor: Int? = nil
        if cursor > 0, isWordChar(chars[cursor - 1]) {
            anchor = cursor - 1
        } else if cursor < chars.count, isWordChar(chars[cursor]) {
            anchor = cursor
        } else if skipOneSeparatorLeft, cursor > 1, !isWordChar(chars[cursor - 1]), !chars[cursor - 1].isNewline,
                  isWordChar(chars[cursor - 2]) {
            anchor = cursor - 2
        }
        guard let anchor else { return nil }

        var start = anchor
        while start > 0, isWordChar(chars[start - 1]) { start -= 1 }
        var end = anchor + 1
        while end < chars.count, isWordChar(chars[end]) { end += 1 }

        let word = String(chars[start..<end])
        guard word.count <= maxWordLength, word.contains(where: { $0.isLetter }) else { return nil }

        // Collect up to 2 preceding words within the same sentence.
        var prevWords: [String] = []
        var idx = start - 1
        while idx >= 0 && prevWords.count < 2 {
            let ch = chars[idx]
            if ch.isNewline || sentenceTerminators.contains(ch) { break }
            if isWordChar(ch) {
                var wStart = idx
                while wStart > 0, isWordChar(chars[wStart - 1]) { wStart -= 1 }
                prevWords.insert(String(chars[wStart...idx]), at: 0)
                idx = wStart - 1
            } else {
                idx -= 1
            }
        }

        // The next word within the same sentence (skip spaces only).
        var nextWord: String? = nil
        var n = end
        while n < chars.count, chars[n] == " " || chars[n] == "\t" { n += 1 }
        if n > end, n < chars.count, isWordChar(chars[n]) {
            var nEnd = n
            while nEnd < chars.count, isWordChar(chars[nEnd]) { nEnd += 1 }
            nextWord = String(chars[n..<nEnd])
        }

        return WordAtCursor(word: word, prevWords: prevWords, nextWord: nextWord)
    }

    /// Decides whether replacing `original` by `edited` is a diacritic correction of the same base word.
    ///
    /// - Parameters:
    ///   - original: word at the edit location before the user started deleting (nil if the app could not report it).
    ///   - edited: word at the edit location after the user finished.
    ///   - recentCommittedWords: words Kodau committed recently (newest last); used to recover the original when
    ///     the host app does not expose its text before the edit.
    public static func candidate(
        original: WordAtCursor?,
        edited: WordAtCursor?,
        recentCommittedWords: [String] = []
    ) -> EditCorrectionCandidate? {
        guard let edited else { return nil }
        let corrected = edited.word
        let base = baseForm(corrected)
        guard isPlausibleBase(base) else { return nil }

        let originalWord: String
        if let original, baseForm(original.word) == base {
            originalWord = original.word
        } else if original == nil,
                  let fromJournal = recentCommittedWords.reversed().first(where: {
                      baseForm($0) == base && $0.lowercased() != corrected.lowercased()
                  }) {
            originalWord = fromJournal
        } else {
            return nil
        }

        guard originalWord.lowercased() != corrected.lowercased() else { return nil }

        let prev = edited.prevWords.map { $0.lowercased() }
        return EditCorrectionCandidate(
            baseWord: base,
            originalSurface: originalWord,
            correctedSurface: corrected,
            prev1: prev.last,
            prev2: prev.count >= 2 ? prev[prev.count - 2] : nil,
            next1: edited.nextWord?.lowercased()
        )
    }

    /// ASCII lowercase base form (`Bạn` → `ban`).
    public static func baseForm(_ word: String) -> String {
        VNIEngine.stripDiacritics(word).lowercased()
    }

    // MARK: - Private

    private static let sentenceTerminators: Set<Character> = [".", "!", "?", ";", ":"]

    private static func isWordChar(_ ch: Character) -> Bool {
        ch.isLetter || ch.isNumber || ch == "'" || ch == "_" || ch == "-"
    }

    private static func isPlausibleBase(_ base: String) -> Bool {
        guard !base.isEmpty, base.count <= maxWordLength else { return false }
        return base.unicodeScalars.allSatisfy { ("a"..."z").contains($0) }
    }
}
