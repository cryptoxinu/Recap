import Testing
import Foundation
@testable import CallBrainCore

@Suite("CategoryEngine (config-driven ventures)")
struct CategoryEngineTests {

    // Test ventures — supplied like a user would configure in Settings (no hardcoded company vocab).
    let ventures: [Venture] = [
        Venture(id: "ambient", label: "Ambient",
                keywords: ["bitrouter", "vllm", "gpu", "miner", "validator", "tokenomics", "on-chain", "inference"]),
        Venture(id: "further_health", label: "Further Health",
                keywords: ["blood lab", "biomarker", "peptide", "genome", "wearable", "hrv", "clinical", "nutrition"]),
    ]

    @Test("a call matching a venture's keywords classifies to that venture with strong confidence")
    func matchesVenture() {
        let r = CategoryHeuristic(ventures: ventures).classify(
            "Discussed the BitRouter gateway, vLLM patches for the GPU miners, and validator tokenomics on-chain.")
        #expect(r.category == "ambient")
        #expect(r.confidence > 0.7)
    }

    @Test("a call matching the OTHER venture's keywords classifies there")
    func matchesSecondVenture() {
        let r = CategoryHeuristic(ventures: ventures).classify(
            "Reviewed the blood lab biomarkers, the peptide protocol, genome screening and wearable HRV data.")
        #expect(r.category == "further_health")
        #expect(r.confidence > 0.7)
    }

    @Test("a call with no venture vocabulary is 'other' at low confidence (so it can escalate)")
    func other() {
        let r = CategoryHeuristic(ventures: ventures).classify("Quick chat about the office lease and the holiday schedule.")
        #expect(r.category == kOtherVentureID)
        #expect(r.confidence < CategoryEngine.escalateBelow)
    }

    @Test("a near-tie scores low confidence (triggers the LLM tiebreaker)")
    func ambiguous() {
        let r = CategoryHeuristic(ventures: ventures).classify("We touched on BitRouter and also a wearable idea.")
        #expect(r.confidence < CategoryEngine.escalateBelow)
    }

    @Test("a SINGLE keyword stays below the escalate threshold → LLM tiebreaker runs")
    func singleKeywordNotConfident() {
        let r = CategoryHeuristic(ventures: ventures).classify("Quick call — we should tweak one gpu setting.")
        #expect(r.confidence < CategoryEngine.escalateBelow)
    }

    @Test("with NO ventures configured, everything is 'other' (nothing personal is baked in)")
    func noVentures() {
        let r = CategoryHeuristic(ventures: []).classify("BitRouter miners and vLLM throughput on the GPU nodes.")
        #expect(r.category == kOtherVentureID)
    }

    @Test("VentureConfig ships EMPTY and round-trips through UserDefaults")
    func configEmptyAndPersists() throws {
        let d = try #require(UserDefaults(suiteName: "cb-ventures-\(UUID().uuidString)"))
        #expect(VentureConfig.load(d).isEmpty)                       // shipped default = no company names
        VentureConfig.save(ventures, d)
        #expect(VentureConfig.load(d) == ventures)
        #expect(VentureConfig.label(for: "ambient", in: ventures) == "Ambient")
        #expect(VentureConfig.label(for: "other", in: ventures) == "Other")
        #expect(VentureConfig.label(for: nil, in: ventures) == "Other")
        #expect(VentureConfig.label(for: "deleted_id", in: ventures) == "Deleted Id")   // orphan → titlecased
    }

    @Test("slug makes a stable, safe id and never collides with the reserved 'other'")
    func slugging() {
        #expect(VentureConfig.slug("Acme Labs") == "acme_labs")
        #expect(VentureConfig.slug("Further Health!") == "further_health")
        #expect(VentureConfig.slug("Other") == "venture_other")     // reserved id is avoided
        #expect(!VentureConfig.slug("   ").isEmpty)
    }

    @Test("freshID appends a suffix and avoids existing ids so a deleted venture's id is never reused (#6)")
    func freshIDUnique() {
        var seq: UInt32 = 0
        let gen: () -> UInt32 = { seq += 1; return seq }   // deterministic for the test
        let a = VentureConfig.freshID(for: "Acme", existing: [], random: gen)
        let b = VentureConfig.freshID(for: "Acme", existing: [a], random: gen)
        #expect(a.hasPrefix("acme-"))
        #expect(a != b)                               // re-adding the same name yields a NEW id
        #expect(a != "acme" && a != VentureConfig.slug("Acme"))  // never a bare reusable slug
    }

    @Test("duplicate keywords are counted once — a repeat can't inflate confidence (#5)")
    func duplicateKeywordsScoreOnce() {
        let dupd = [Venture(id: "acme", label: "Acme", keywords: ["acme", "acme", "acme"])]
        let r = CategoryHeuristic(ventures: dupd).classify("We talked about acme today.")
        // One distinct matched term → stays below the escalate threshold (not a confident 0.8).
        #expect(r.confidence < CategoryEngine.escalateBelow)
    }

    @Test("CategoryEngine with no LLM falls back to the heuristic")
    func engineHeuristicFallback() async {
        let engine = CategoryEngine(ventures: ventures, classifier: nil)
        let r = await engine.categorize(text: "BitRouter miners and vLLM throughput on the GPU nodes.")
        #expect(r.category == "ambient")
    }
}
