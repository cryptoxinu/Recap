import Foundation
import Testing
@testable import CallBrainCore

@Suite("Follow-up intent routing")
struct FollowUpIntentTests {
    // A prior exchange so history carries an assistant turn.
    let history: [AskEngine.Turn] = [
        .init(role: .user, text: "What did Dom say about the Radium machines?"),
        .init(role: .assistant, text: "Dom said the Radium machines drive the COGS and you should track model-on-machine."),
    ]

    @Test("a pronoun-less follow-up ('what about the pricing angle') CONTINUES, not fresh (the founder's case)")
    func drillDownPronounless() {
        #expect(AskEngine.followUpIntent("what about the pricing angle?", history: history) == .drillDown)
        #expect(AskEngine.followUpIntent("more on the competitive risks", history: history) == .drillDown)
    }

    @Test("'tell me more' / 'go deeper' / 'what else' BROADENS")
    func broaden() {
        #expect(AskEngine.followUpIntent("tell me more", history: history) == .broaden)
        #expect(AskEngine.followUpIntent("can you go deeper on that", history: history) == .broaden)
        #expect(AskEngine.followUpIntent("what else did they cover", history: history) == .broaden)
    }

    @Test("short and pronoun follow-ups CONTINUE")
    func drillDownShortPronoun() {
        #expect(AskEngine.followUpIntent("what did he commit to", history: history) == .drillDown)
        #expect(AskEngine.followUpIntent("summarize it", history: history) == .drillDown)
        #expect(AskEngine.followUpIntent("dig into that", history: history) == .drillDown)
    }

    @Test("a self-contained new question is STANDALONE — even when short or containing 'this'/'and'")
    func standaloneNewTopic() {
        #expect(AskEngine.followUpIntent("what are my open action items this week", history: history) == .standalone)
        #expect(AskEngine.followUpIntent("summarize yesterday's product sync", history: history) == .standalone)
        // Short-but-COMPLETE questions are not follow-ups (Part-B audit HIGH — meaningful<4 misrouted these).
        #expect(AskEngine.followUpIntent("how do validators work", history: history) == .standalone)
        #expect(AskEngine.followUpIntent("summarize yesterday's sync", history: history) == .standalone)
        // A MID-sentence "and the" is not a continuation (Part-B audit HIGH — over-broad cue).
        #expect(AskEngine.followUpIntent("what happened and the fallout", history: history) == .standalone)
    }

    @Test("a LEADING 'and…' / 'also…' IS a continuation")
    func leadingAnd() {
        #expect(AskEngine.followUpIntent("and Priya?", history: history) == .drillDown)
        #expect(AskEngine.followUpIntent("and the competitive risks", history: history) == .drillDown)
    }

    @Test("no prior answer → always standalone (nothing to continue)")
    func noHistory() {
        #expect(AskEngine.followUpIntent("tell me more", history: []) == .standalone)
    }

    @Test("references to the PRIOR ANSWER continue the thread — founder: 'summarize what you just said' re-scraped the call")
    func answerReferenceContinues() {
        #expect(AskEngine.followUpIntent("summarize everything you just said", history: history) == .drillDown)
        #expect(AskEngine.followUpIntent("can you recap that for me", history: history) == .drillDown)
        #expect(AskEngine.followUpIntent("give me the tl;dr of your last answer", history: history) == .drillDown)
        #expect(AskEngine.followUpIntent("rephrase that more simply", history: history) == .drillDown)
        #expect(AskEngine.followUpIntent("shorten that", history: history) == .drillDown)
        // A FRESH 'summarize this call' (no back-reference to the answer) still stands alone — a real re-summary.
        #expect(AskEngine.followUpIntent("summarize this call", history: history) == .standalone)
        // With only a user turn (no assistant answer yet) there's nothing to refer back to → standalone.
        #expect(AskEngine.followUpIntent("summarize what you just said",
                                         history: [.init(role: .user, text: "hi")]) == .standalone)
    }

    @Test("retrievalQuery folds the prior turn in for a continuation, not for a fresh question")
    func retrievalEnrichment() {
        let drill = AskEngine.retrievalQuery("what about the pricing angle?", history: history, intent: .drillDown)
        #expect(drill.contains("Radium"))        // carries the prior subject forward
        #expect(drill.contains("pricing"))
        let broaden = AskEngine.retrievalQuery("tell me more", history: history, intent: .broaden)
        #expect(broaden.contains("Radium"))       // broaden also continues the subject
        let fresh = AskEngine.retrievalQuery("what are my open action items this week", history: history, intent: .standalone)
        #expect(fresh == "what are my open action items this week")   // stands alone, no thread
    }
}
