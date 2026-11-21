import Testing
import Foundation
@testable import KodauCore

@Suite("DiacriticVariants")
struct DiacriticVariantsTests {

    @Test("`ban` yields the expected toned forms")
    func banForms() {
        let forms = DiacriticVariants.all(for: "ban", rawCasing: "ban")
        let expected = ["bán", "bàn", "bản", "bạn", "bần", "bẩn", "bận", "bắn"]
        for word in expected {
            #expect(forms.contains(word), "missing \(word) in \(forms)")
        }
    }

    @Test("Every generated form strips back to the requested base")
    func everyFormStripsToBase() {
        for base in ["ban", "dau", "duoc", "tieng", "hoa", "thuong", "meo"] {
            let forms = DiacriticVariants.all(for: base, rawCasing: base)
            for form in forms {
                #expect(VNIEngine.stripDiacritics(form).lowercased() == base, "\(form) does not strip to \(base)")
            }
        }
    }

    @Test("The plain ASCII form is only present when it was already a candidate")
    func asciiOnlyWhenOffered() {
        let plain = DiacriticVariants.all(for: "ban", rawCasing: "ban")
        #expect(!plain.contains("ban"))

        let withCandidate = DiacriticVariants.all(for: "ban", rawCasing: "ban", currentCandidates: ["ban"])
        #expect(withCandidate.first == "ban")
    }

    @Test("Casing of the typed word is preserved")
    func casingPreserved() {
        let capitalized = DiacriticVariants.all(for: "Ban", rawCasing: "Ban")
        #expect(capitalized.contains("Bạn"))
        #expect(capitalized.contains("Bán"))
        #expect(capitalized.allSatisfy { $0.first?.isUppercase == true })

        let upper = DiacriticVariants.all(for: "BAN", rawCasing: "BAN")
        #expect(upper.contains("BẠN"))
        #expect(upper.allSatisfy { $0 == $0.uppercased() })
    }

    @Test("No duplicates, and the cap is respected")
    func deduplicatedAndCapped() {
        let forms = DiacriticVariants.all(for: "ban", rawCasing: "ban", limit: 40)
        #expect(Set(forms.map { $0.lowercased() }).count == forms.count)
        #expect(forms.count <= 40)

        let small = DiacriticVariants.all(for: "ban", rawCasing: "ban", limit: 3)
        #expect(small.count == 3)
    }

    @Test("Current candidates come first, in their order")
    func currentCandidatesFirst() {
        let forms = DiacriticVariants.all(
            for: "ban",
            rawCasing: "ban",
            currentCandidates: ["bận", "bản", "ban"]
        )
        #expect(Array(forms.prefix(3)) == ["bận", "bản", "ban"])
    }

    @Test("Seed lexicon weight ranks known words ahead of the rest")
    func seedWeightsRankFirst() {
        let forms = DiacriticVariants.all(for: "ban", rawCasing: "ban")
        // `bạn` is the highest-weighted seed entry for `ban`, so it leads the generated list.
        #expect(forms.first == "bạn")
    }

    @Test("`d` onset alternatives include the `đ` forms")
    func strokeDForms() {
        let forms = DiacriticVariants.all(for: "dau", rawCasing: "dau")
        #expect(forms.contains("đâu"))
        #expect(forms.contains("đấu"))
        #expect(forms.contains("dấu"))
    }

    @Test("Modern vs classic tone placement is respected")
    func toneStyle() {
        let modern = DiacriticVariants.all(for: "hoa", rawCasing: "hoa", preferFirstVowel: true)
        let classic = DiacriticVariants.all(for: "hoa", rawCasing: "hoa", preferFirstVowel: false)
        #expect(modern.contains("hòa"))
        #expect(classic.contains("hoà"))
    }

    @Test("Invalid bases produce nothing")
    func invalidBases() {
        #expect(DiacriticVariants.all(for: "xyzzy", rawCasing: "xyzzy").isEmpty)
        #expect(DiacriticVariants.all(for: "", rawCasing: "").isEmpty)
        #expect(DiacriticVariants.all(for: "hello", rawCasing: "hello").isEmpty)
    }
}
