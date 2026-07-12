import Testing
import Foundation
@testable import CallBrainCore

/// Local-summaries v2 — the pure logic: fact merging, label sanitizing, deterministic render.
@Suite("Summary facts (v2 pipeline)")
struct SummaryFactsTests {

    @Test("merge dedupes near-identical facts across windows")
    func testMergeDedupe() {
        var a = MeetingFacts()
        a.decisions = [.init(what: "Deploy Kimi K2.7 ASAP", who: "Dom")]
        a.commitments = [.init(owner: "Marco", task: "Merge the auction PR", due: nil)]
        var b = MeetingFacts()
        b.decisions = [.init(what: "Deploy Kimi K2.7 ASAP!", who: nil)]     // punctuation-only diff
        b.updates = [.init(topic: "Tracing", detail: "ready for review", who: nil)]
        let m = MeetingFacts.merge([a, b])
        #expect(m.decisions.count == 1)
        #expect(m.commitments.count == 1)
        #expect(m.updates.count == 1)
    }

    @Test("sanitized drops Speaker-N labels but keeps real names, including in mixed lists")
    func testSanitize() {
        var f = MeetingFacts()
        f.decisions = [.init(what: "x", who: "Speaker 3")]
        f.blockers = [.init(what: "y", who: "Speaker 3, Speaker 4")]
        f.updates = [.init(topic: "t", detail: "d", who: "Speaker 1, Riley")]
        f.commitments = [.init(owner: "Speaker 2", task: "do it", due: nil),
                         .init(owner: "Marco", task: "ship it", due: "Friday")]
        let s = f.sanitized()
        #expect(s.decisions[0].who == nil)
        #expect(s.blockers[0].who == nil)
        #expect(s.updates[0].who == "Riley")
        #expect(s.commitments[0].owner == nil)
        #expect(s.commitments[1].owner == "Marco")
    }

    @Test("render is structured by construction: TL;DR + sections + owner-attributed next steps")
    func testRender() {
        var f = MeetingFacts()
        f.decisions = [.init(what: "Limit referral discount to 3 months", who: "Priya")]
        f.blockers = [.init(what: "Blue-sky machines unpaid for April/May", who: nil)]
        f.commitments = [.init(owner: "Riley", task: "Review the GLM benchmark", due: "Friday")]
        let md = FactPrompt.render(tldr: "Referrals capped; payout blocker open.", facts: f)
        #expect(md.hasPrefix("**TL;DR:** Referrals capped"))
        #expect(md.contains("## Decisions"))
        #expect(md.contains("- **Priya** — Limit referral discount to 3 months"))
        #expect(md.contains("## Blockers"))
        #expect(md.contains("## Next steps"))
        #expect(md.contains("- **Riley** — Review the GLM benchmark (Friday)"))
        #expect(!md.contains("## Updates"))                        // empty section omitted
    }

    @Test("vague tripwire catches the historical mush; fallback TL;DR is specific")
    func testVagueAndFallback() {
        #expect(FactPrompt.isVague("The meeting covered updates on PRs and ongoing projects."))
        #expect(!FactPrompt.isVague("Kimi K2.7 deploys tomorrow; profit share for May is blocked."))
        var f = MeetingFacts()
        f.decisions = [.init(what: "Ship the billing fix", who: nil)]
        #expect(FactPrompt.fallbackTLDR(f) == "Decided: Ship the billing fix")
    }

    @Test("commitments parser tolerates prefixed replies and preserves fields")
    func testParseCommitments() {
        let json = #"{"commitments":[{"owner":"Leo","task":"Deploy the K2.7 config","due":"tomorrow"}]}"#
        let c = FactPrompt.parseCommitments(json)
        #expect(c?.first?.owner == "Leo")
        #expect(c?.first?.due == "tomorrow")
        #expect(FactPrompt.parseCommitments("not json") == nil)
    }
}

/// v2 gate regressions: merge-key separators, render flattening, sanitizer variants.
@Suite("Summary facts (gate regressions)")
struct SummaryFactsGateTests {
    @Test("K2.7 and K27 do NOT merge; punctuation presence survives the key")
    func testMergeKeySeparators() {
        var a = MeetingFacts(); a.updates = [.init(topic: "Kimi", detail: "K2.7 shipped", who: nil)]
        var b = MeetingFacts(); b.updates = [.init(topic: "Kimi", detail: "K27 shipped", who: nil)]
        #expect(MeetingFacts.merge([a, b]).updates.count == 2)
    }

    @Test("render flattens structure-faking fact text")
    func testRenderFlattening() {
        var f = MeetingFacts()
        f.decisions = [.init(what: "ship it\n## Fake Section\n- fake bullet", who: nil)]
        let md = FactPrompt.render(tldr: "t l d r", facts: f)
        #expect(!md.contains("## Fake Section"))
        #expect(md.contains("## Decisions"))
    }

    @Test("sanitizer handles case, spacing, tight commas, and 'and' lists")
    func testSanitizerVariants() {
        var f = MeetingFacts()
        f.commitments = [.init(owner: "speaker 3 ", task: "a", due: nil),
                         .init(owner: "Speaker 3,Speaker 4", task: "b", due: nil),
                         .init(owner: "Speaker 3 and Riley", task: "c", due: nil)]
        let s = f.sanitized()
        #expect(s.commitments[0].owner == nil)
        #expect(s.commitments[1].owner == nil)
        #expect(s.commitments[2].owner == "Riley")
    }
}

/// De-slop gate (founder: 26-38 raw "tasks" per call were noise).
@Suite("Task quality gate")
struct TaskQualityGateTests {
    @Test("rejects artifacts, first person, and vague filler; keeps concrete commitments")
    func testQuality() {
        #expect(!FactPrompt.isQualityTask("I will take a crack at the website and share the link. ()"))
        #expect(!FactPrompt.isQualityTask("Put pressure on customers to ensure good customer satisfaction"))
        #expect(!FactPrompt.isQualityTask("Stay on top of the charts with SV VCs next week"))
        #expect(!FactPrompt.isQualityTask("Do it"))
        #expect(FactPrompt.isQualityTask("Deploy the K2.7 config after Dom's review"))
        #expect(FactPrompt.isQualityTask("Send Junney a full blurb describing Ambient AI"))
        // Precision (gate MED): weak verbs only reject as OPENERS; curly apostrophes caught.
        #expect(FactPrompt.isQualityTask("Review the proposal and consider the contract terms"))
        #expect(!FactPrompt.isQualityTask("Consider the contract terms for the renewal"))
        #expect(!FactPrompt.isQualityTask("I\u{2019}ll take the website draft this week"))
        #expect(!FactPrompt.isQualityTask("We need to sync with Dom about the deploy"))
    }

    @Test("cap 8, owner-attributed first")
    func testCap() {
        let items = (0..<20).map { i in
            MeetingFacts.Commitment(owner: i % 2 == 0 ? "Dom" : nil,
                                    task: "Deploy build number \(i) to the staging cluster", due: nil)
        }
        let gated = FactPrompt.gateCommitments(items)
        #expect(gated.count == 8)
        #expect(gated.prefix(8).filter { $0.owner != nil }.count >= 4)   // owned float up
    }
}
