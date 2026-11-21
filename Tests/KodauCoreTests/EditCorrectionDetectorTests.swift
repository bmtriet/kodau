import Testing
@testable import KodauCore

@Suite("EditCorrectionDetector Tests")
struct EditCorrectionDetectorTests {

    private func offset(of marker: String, in text: String) -> (String, Int) {
        let range = text.range(of: marker)!
        let utf16 = text[..<range.lowerBound].utf16.count
        return (text.replacingOccurrences(of: marker, with: ""), utf16)
    }

    @Test("Finds the word ending at the cursor with two preceding context words")
    func wordEndingAtCursor() {
        let (text, cursor) = offset(of: "|", in: "hôm nay tôi bán| cho em")
        let found = EditCorrectionDetector.wordAtCursor(in: text, cursorUTF16Offset: cursor)
        #expect(found == WordAtCursor(word: "bán", prevWords: ["nay", "tôi"], nextWord: "cho"))
    }

    @Test("Finds the word when cursor sits inside it, after a separator, or before it")
    func wordAroundCursor() {
        let (inside, c1) = offset(of: "|", in: "tôi bạ|n đi")
        #expect(EditCorrectionDetector.wordAtCursor(in: inside, cursorUTF16Offset: c1)?.word == "bạn")

        let (afterSpace, c2) = offset(of: "|", in: "tôi bán |")
        #expect(EditCorrectionDetector.wordAtCursor(in: afterSpace, cursorUTF16Offset: c2)?.word == "bán")

        let (before, c3) = offset(of: "|", in: "|bán")
        #expect(EditCorrectionDetector.wordAtCursor(in: before, cursorUTF16Offset: c3)?.word == "bán")
    }

    @Test("Context stops at sentence boundaries")
    func contextStopsAtSentenceEnd() {
        let (text, cursor) = offset(of: "|", in: "xong rồi. bạn|")
        let found = EditCorrectionDetector.wordAtCursor(in: text, cursorUTF16Offset: cursor)
        #expect(found == WordAtCursor(word: "bạn", prevWords: []))
    }

    @Test("Same-base diacritic change becomes a correction candidate")
    func diacriticCorrection() {
        let candidate = EditCorrectionDetector.candidate(
            original: WordAtCursor(word: "bán", prevWords: ["chào"]),
            edited: WordAtCursor(word: "bạn", prevWords: ["anh", "chào"], nextWord: "Nhé")
        )
        #expect(candidate == EditCorrectionCandidate(
            baseWord: "ban",
            originalSurface: "bán",
            correctedSurface: "bạn",
            prev1: "chào",
            prev2: "anh",
            next1: "nhé"
        ))
    }

    @Test("Different word, identical word, or non-word edits are ignored")
    func ignoresNonCorrections() {
        #expect(EditCorrectionDetector.candidate(
            original: WordAtCursor(word: "đi"),
            edited: WordAtCursor(word: "đến")
        ) == nil)
        #expect(EditCorrectionDetector.candidate(
            original: WordAtCursor(word: "Bạn"),
            edited: WordAtCursor(word: "bạn")
        ) == nil)
        #expect(EditCorrectionDetector.candidate(
            original: WordAtCursor(word: "v2"),
            edited: WordAtCursor(word: "v3")
        ) == nil)
        #expect(EditCorrectionDetector.candidate(original: WordAtCursor(word: "bán"), edited: nil) == nil)
    }

    @Test("Falls back to recently committed words when the app cannot report the original")
    func journalFallback() {
        let candidate = EditCorrectionDetector.candidate(
            original: nil,
            edited: WordAtCursor(word: "tôi", prevWords: []),
            recentCommittedWords: ["tối", "nay", "đi"]
        )
        #expect(candidate?.originalSurface == "tối")
        #expect(candidate?.correctedSurface == "tôi")
    }

    @Test("Reverting a converted word back to plain ASCII is also learnable")
    func revertToPlain() {
        let candidate = EditCorrectionDetector.candidate(
            original: WordAtCursor(word: "bạn"),
            edited: WordAtCursor(word: "ban", prevWords: ["rock"])
        )
        #expect(candidate?.correctedSurface == "ban")
        #expect(candidate?.prev1 == "rock")
    }
}
