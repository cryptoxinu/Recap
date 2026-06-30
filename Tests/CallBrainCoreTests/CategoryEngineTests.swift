import Testing
import Foundation
@testable import CallBrainCore

@Suite("CategoryEngine (Ambient / Further Health / Other)")
struct CategoryEngineTests {

    @Test("an Ambient (crypto-inference) call classifies as ambient with strong confidence")
    func ambient() {
        let r = CategoryHeuristic.classify(
            "Discussed the BitRouter gateway, vLLM patches for the GPU miners, and validator tokenomics on-chain.")
        #expect(r.category == .ambient)
        #expect(r.confidence > 0.7)
    }

    @Test("a Further Health call classifies as further_health")
    func furtherHealth() {
        let r = CategoryHeuristic.classify(
            "Reviewed the blood lab biomarkers, the peptide protocol, genome screening and wearable HRV data.")
        #expect(r.category == .furtherHealth)
        #expect(r.confidence > 0.7)
    }

    @Test("a call with neither vocabulary is 'other' at low confidence (so it can escalate)")
    func other() {
        let r = CategoryHeuristic.classify("Quick chat about the office lease and the holiday schedule.")
        #expect(r.category == .other)
        #expect(r.confidence < CategoryEngine.escalateBelow)
    }

    @Test("a near-tie scores low confidence (triggers the LLM tiebreaker)")
    func ambiguous() {
        // one signal each
        let r = CategoryHeuristic.classify("We touched on BitRouter and also a wearable idea.")
        #expect(r.confidence < CategoryEngine.escalateBelow)
    }

    @Test("CallCategory round-trips its stored raw value and defaults to .other")
    func storedMapping() {
        #expect(CallCategory(stored: "ambient") == .ambient)
        #expect(CallCategory(stored: "further_health") == .furtherHealth)
        #expect(CallCategory(stored: "other") == .other)
        #expect(CallCategory(stored: nil) == .other)
        #expect(CallCategory(stored: "garbage") == .other)
        #expect(CallCategory.furtherHealth.label == "Further Health")
    }

    @Test("CategoryEngine with no LLM falls back to the heuristic")
    func engineHeuristicFallback() async {
        let engine = CategoryEngine(classifier: nil)        // no LLM available
        let r = await engine.categorize(text: "BitRouter miners and vLLM throughput on the GPU nodes.")
        #expect(r.category == .ambient)
    }
}
