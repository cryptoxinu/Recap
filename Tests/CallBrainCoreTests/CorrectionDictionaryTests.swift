import Testing
import Foundation
@testable import CallBrainCore

@Suite("CorrectionDictionary")
struct CorrectionDictionaryTests {
    private func dict(_ entries: [CorrectionEntry], watch: [String] = []) -> CorrectionDictionary {
        CorrectionDictionary(entries: entries, watchlist: watch)
    }

    @Test("applies whole-word, case-insensitive, canonical casing out")
    func testApplyWholeWord() {
        let d = dict([CorrectionEntry(wrong: "solano", right: "Solana")])
        #expect(d.apply(to: "We ship on Solano and SOLANO next week.") == "We ship on Solana and Solana next week.")
        // Whole-word only — must NOT corrupt a substring inside another word.
        #expect(d.apply(to: "solanoid device") == "solanoid device")
    }

    @Test("longer phrases win over shorter overlapping ones")
    func testLongerPhrasesFirst() {
        let d = dict([
            CorrectionEntry(wrong: "sole", right: "Sole"),
            CorrectionEntry(wrong: "sole labs", right: "Solana Labs"),
        ])
        #expect(d.apply(to: "met with sole labs today") == "met with Solana Labs today")
    }

    @Test("case-only corrections apply (ethereum → Ethereum) — audit MED")
    func testCaseOnlyCorrectionApplies() {
        let d = dict([CorrectionEntry(wrong: "ethereum", right: "Ethereum")])
        #expect(d.apply(to: "i bought ethereum and ETHEREUM") == "i bought Ethereum and Ethereum")
    }

    @Test("terms with non-word edges ($SOL, C#, .NET) match on token boundaries — audit MED")
    func testNonAlnumEdges() {
        let d = dict([
            CorrectionEntry(wrong: "$sol", right: "$SOL"),
            CorrectionEntry(wrong: "c sharp", right: "C#"),
        ])
        #expect(d.apply(to: "buy $sol now") == "buy $SOL now")
        #expect(d.apply(to: "wrote c sharp code") == "wrote C# code")
        // Must not fire mid-word.
        #expect(d.apply(to: "unsold inventory") == "unsold inventory")
    }

    @Test("single pass against original spans — an output is never re-scanned mid-pass — audit MED")
    func testNoCascadeReMatchInPass() {
        // Independent (non-chained) corrections: each ORIGINAL token maps exactly once; a produced token
        // is not re-scanned. "yterm" (output of xterm) is not itself a wrong, so no cascade.
        let d = dict([
            CorrectionEntry(wrong: "xterm", right: "yterm"),
            CorrectionEntry(wrong: "zterm", right: "wterm"),
        ])
        #expect(d.apply(to: "xterm and zterm") == "yterm and wterm")
    }

    @Test("chained corrections collapse to their terminal, so repeated apply is idempotent — audit MED")
    func testChainedCorrectionsCollapse() {
        // "alpha"→"beta" + "beta"→"gamma" collapses at build time to alpha→gamma, beta→gamma.
        let d = dict([
            CorrectionEntry(wrong: "alpha", right: "beta"),
            CorrectionEntry(wrong: "beta", right: "gamma"),
        ])
        let once = d.apply(to: "alpha and beta")
        #expect(once == "gamma and gamma")
        #expect(d.apply(to: once) == once)   // idempotent: re-applying changes nothing
    }

    @Test("a no-op entry (wrong == right) and empty dict are safe")
    func testNoOpAndEmpty() {
        #expect(dict([]).apply(to: "unchanged text") == "unchanged text")
        let d = dict([CorrectionEntry(wrong: "Ethereum", right: "Ethereum")])
        #expect(d.apply(to: "Ethereum rocks") == "Ethereum rocks")
    }

    @Test("apply(to: ParsedTranscript) corrects every utterance's text")
    func testApplyToTranscript() {
        let d = dict([CorrectionEntry(wrong: "aetherium", right: "Ethereum")])
        let t = ParsedTranscript(source: .gmeetLocal, utterances: [
            ParsedUtterance(seq: 0, speakerRaw: "You", tStart: 0, tEnd: 1, text: "aetherium is up"),
            ParsedUtterance(seq: 1, speakerRaw: "Them", tStart: 1, tEnd: 2, text: "yes AETHERIUM"),
        ])
        let out = d.apply(to: t)
        #expect(out.utterances.map(\.text) == ["Ethereum is up", "yes Ethereum"])
    }

    @Test("biasTerms dedupes watchlist + correction rights and caps")
    func testBiasTerms() {
        let d = dict([CorrectionEntry(wrong: "solano", right: "Solana")], watch: ["Ethereum", "solana", "DeFi"])
        let terms = d.biasTerms(limit: 10)
        // "solana" (watch) and "Solana" (right) dedupe case-insensitively → one entry.
        #expect(terms.filter { $0.lowercased() == "solana" }.count == 1)
        #expect(terms.contains("Ethereum"))
        #expect(d.biasTerms(limit: 2).count == 2)
    }

    @Test("upserting adds, versions on change, and teaches the glossary the canonical term")
    func testUpsert() {
        var d = dict([])
        d = d.upserting(CorrectionEntry(wrong: "x four oh two", right: "x402", origin: .manual))
        #expect(d.entries.count == 1)
        #expect(d.watchlist.contains("x402"))             // canonical term added to the glossary
        d = d.upserting(CorrectionEntry(wrong: "x four oh two", right: "x402 protocol"))
        #expect(d.entries.count == 1)                     // same key → replace, not duplicate
        #expect(d.entries[0].version == 1)                // right changed → version bumped
    }

    @Test("isRiskyWrong flags short + common words but allows names/jargon — audit MED")
    func testIsRiskyWrong() {
        #expect(CorrectionDictionary.isRiskyWrong("there"))     // common homophone
        #expect(CorrectionDictionary.isRiskyWrong("a"))         // too short
        #expect(CorrectionDictionary.isRiskyWrong("the"))
        #expect(!CorrectionDictionary.isRiskyWrong("aetherium"))   // not a common word
        #expect(!CorrectionDictionary.isRiskyWrong("Solana"))      // capitalized → name
        #expect(!CorrectionDictionary.isRiskyWrong("$sol"))        // symbol → jargon
        #expect(!CorrectionDictionary.isRiskyWrong("sole labs"))   // multi-word → phrase
    }

    @Test("a reused Applicator matches per-call apply (compile once, apply many)")
    func testApplicatorReuse() {
        let d = dict([CorrectionEntry(wrong: "aetherium", right: "Ethereum"),
                      CorrectionEntry(wrong: "solano", right: "Solana")])
        let app = d.makeApplicator()
        #expect(app.apply(to: "aetherium and solano") == d.apply(to: "aetherium and solano"))
        #expect(app.apply(to: "aetherium and solano") == "Ethereum and Solana")
    }

    @Test("seed loads and merges over saved (new seed terms surface without clobbering learned ones)")
    func testLoadMergesSeed() {
        let key = "callbrain.correctionDictionary.test-\(UUID().uuidString)"
        // Saved has one learned entry but an OLD (smaller) watchlist.
        dict([CorrectionEntry(wrong: "my term", right: "MyTerm", origin: .manual)], watch: ["OnlyOld"]).save(key: key)
        let loaded = CorrectionDictionary.load(key: key)
        #expect(loaded.entries.contains { $0.id == "my term" })          // learned entry kept
        #expect(loaded.watchlist.contains("Ethereum"))                    // seed term merged in
        #expect(loaded.watchlist.contains("OnlyOld"))                     // user term kept
        UserDefaults.standard.removeObject(forKey: key)
    }
}
