import Testing
@testable import CallBrainCore

/// Owner de-fragmentation (the founder's "it's all noise" — same person under 6 spellings). These lock
/// the SAFE-merge boundary: fold obvious variants of one person, NEVER merge two different people.
@Suite("OwnerResolver — task-owner canonicalization")
struct OwnerResolverTests {

    private func map(_ counts: [String: Int]) -> [String: String] {
        OwnerResolver.canonicalMap(ownerCounts: counts)
    }

    @Test("Whisper's misspelled surnames of one person fold to the most-frequent full spelling")
    func misspelledSurnames() {
        let m = map(["Priya Anand": 10, "Priya Ananda": 3, "Priya Anandi": 2,
                     "Priya Anande": 1, "Preya": 4, "Priya": 6])
        // All the Priya-* fulls collapse to the dominant, complete spelling.
        #expect(m["Priya Anand"] == "Priya Anand")
        #expect(m["Priya Ananda"] == "Priya Anand")
        #expect(m["Priya Anande"] == "Priya Anand")
        // The bare "Priya" first name folds in too (one full-name cluster for that first name).
        #expect(m["Priya"] == "Priya Anand")
        // "Preya" is a different first token (mis-heard first name) — it does NOT fold here (conservative).
        #expect(m["Preya"] == "Preya")
    }

    @Test("bare first name folds into the single matching full name")
    func firstNameToFull() {
        let m = map(["Dominic Vance": 8, "Dom Vance": 2, "Dom": 17])
        #expect(m["Dom"] == "Dominic Vance")
        #expect(m["Dom Vance"] == "Dominic Vance")
        #expect(m["Dominic Vance"] == "Dominic Vance")
    }

    @Test("short + full forms of one person fold together")
    func shortAndFullForms() {
        let m = map(["Jordan Lee": 29, "Jordan": 4])
        #expect(m["Jordan"] == "Jordan Lee")
        #expect(m["Jordan Lee"] == "Jordan Lee")
    }

    @Test("parenthetical asides on an owner are stripped before folding")
    func parentheticalsStripped() {
        let m = map(["Jordan Lee": 10, "Jordan (or Sam)": 2, "Dana (Danielle)": 3])
        #expect(m["Jordan (or Sam)"] == "Jordan Lee")   // "(or Sam)" dropped, bare "Jordan" folds in
        #expect(m["Dana (Danielle)"] == "Dana")         // "(Danielle)" dropped
    }

    @Test("TWO different people sharing a first name are NOT merged (bare name stays ambiguous)")
    func ambiguousFirstNameNotMerged() {
        let m = map(["Chris Ibarra": 20, "Chris Delgado": 5, "Chris": 17])
        #expect(m["Chris Ibarra"] == "Chris Ibarra")
        #expect(m["Chris Delgado"] == "Chris Delgado")
        #expect(m["Chris"] == "Chris")   // can't disambiguate → left as-is, never mis-merged
    }

    @Test("distinct surnames are never merged")
    func distinctSurnamesStay() {
        let m = map(["Noah Ashford": 10, "Noah": 4])
        #expect(m["Noah"] == "Noah Ashford")
        // A different Noah surname stays separate.
        let m2 = map(["Noah Ashford": 10, "Noah Whitfield": 8])
        #expect(m2["Noah Ashford"] == "Noah Ashford")
        #expect(m2["Noah Whitfield"] == "Noah Whitfield")
    }

    @Test("multi-owner comma blobs canonicalize each part and de-dup")
    func multiOwner() {
        let m = map(["Priya Anand": 5, "Marco Ruiz": 5, "Dom": 5,
                     "Priya Ananda, Marco, Dominic Vance": 1])
        #expect(m["Priya Ananda, Marco, Dominic Vance"] == "Priya Anand, Marco Ruiz, Dominic Vance")
    }

    @Test("deterministic on ties — same input yields same canonical every run")
    func deterministic() {
        // Same-count, same-length names that could tie-break differently by dict order.
        let counts = ["Dana Cole": 5, "Dana Coley": 5, "Sam Ortiz": 5, "Sam Ortez": 5]
        let a = OwnerResolver.canonicalMap(ownerCounts: counts)
        for _ in 0..<25 {   // dictionary iteration order varies run-to-run; result must not
            #expect(OwnerResolver.canonicalMap(ownerCounts: counts) == a)
        }
    }

    @Test("whitespace + casing normalized without merging real distinctions")
    func normalization() {
        let m = map(["  riley   novak ": 3, "Riley Novak": 5])
        #expect(m["  riley   novak "] == "Riley Novak")
        #expect(m["Riley Novak"] == "Riley Novak")
    }
}
