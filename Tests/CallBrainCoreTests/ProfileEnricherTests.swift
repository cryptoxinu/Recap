import Testing
import Foundation
@testable import CallBrainCore

/// Perfection plan Task 8.6 (founder directive) — the profile learns the job FROM the calls:
/// recurring topics become focus-area suggestions, recurring people become who's-who lines.
/// Nothing self-modifies: suggestions require one-tap accept, and accepting twice no-ops.
@Suite("Profile enricher (Task 8.6)")
struct ProfileEnricherTests {

    private func seeded() throws -> Store {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-enrich-\(UUID().uuidString).sqlite").path
        let store = try Store(path: path)
        for i in 0..<3 {
            let mid = "m\(i)"
            try store.saveMeeting(Meeting(id: mid, title: "Call \(i)", date: "2026-06-2\(5 + i)", source: .fireflies),
                chunks: [Store.ChunkInput(chunkID: "\(mid)c0", meetingID: mid, version: 0, seq: 0,
                                          speaker: "T", tStart: 0, tEnd: 5, text: "x", contentHash: "b:\(mid)c0")],
                entities: [Store.EntityInput(name: "BitRouter", kind: "organization", count: 5),
                           Store.EntityInput(name: "Riley Novak", kind: "person", count: 6)])
        }
        return store
    }

    @Test("recurring topics become suggestions; PEOPLE never do (founder: collaborator rows were noise)")
    func testSuggestions() throws {
        let store = try seeded()
        var profile = PersonalProfile.defaultProfile
        let s1 = try ProfileEnricher.suggestions(store: store, profile: profile, minMeetings: 3)
        #expect(s1.contains(where: { $0.kind == .focusArea && $0.text == "BitRouter" }))
        #expect(!s1.contains(where: { $0.kind == .person }))
        // Accept the focus area → suggesting again EXCLUDES it (merge idempotence).
        profile = ProfileEnricher.accept(s1.first(where: { $0.kind == .focusArea })!, into: profile)
        #expect(profile.focusAreas.contains("BitRouter"))
        let s2 = try ProfileEnricher.suggestions(store: store, profile: profile)
        #expect(!s2.contains(where: { $0.kind == .focusArea && $0.text == "BitRouter" }))
        // Accepting the SAME suggestion twice no-ops (no duplicates).
        let again = ProfileEnricher.accept(s1.first(where: { $0.kind == .focusArea })!, into: profile)
        #expect(again.focusAreas.filter { $0 == "BitRouter" }.count == 1)
    }

    @Test("AI profile draft JSON parses into a structured profile plus aliases")
    func testProfileDraftParsing() throws {
        let json = """
        {
          "role": "Founder / operator",
          "company": "Ambient-style decentralized AI infrastructure",
          "focusAreas": ["BitRouter", "Proof of Logits", "Slackbot follow-ups"],
          "expertiseNote": "Explain crypto and AI infrastructure jargon plainly.",
          "extras": ["Prefers direct for-you vs team separation"],
          "aliases": ["Alex", "Sam", "Alex King"]
        }
        """
        let draft = try ProfileEnricher.parseProfileDraft(json, rawAbout: "I am Alex / Sam.")
        #expect(draft.profile.role == "Founder / operator")
        #expect(draft.profile.rawAbout == "I am Alex / Sam.")
        #expect(draft.profile.focusAreas.contains("Slackbot follow-ups"))
        #expect(draft.aliases == ["Alex", "Sam", "Alex King"])
    }

    @Test("shipped default profile is PII-free and not the stale new-hire ops copy")
    func testDefaultProfileIsNeutral() {
        let p = PersonalProfile.defaultProfile
        // No baked-in personal identity — role/company are blank until the user fills them in Settings.
        #expect(p.role.isEmpty)
        #expect(p.company.isEmpty)
        #expect(!p.role.lowercased().contains("new hire"))
        // But it still carries the load-bearing jargon-gloss instruction.
        #expect(p.promptBlock.contains("plain-language gloss"))
        #expect(!PersonalProfile.supersededDefaults.contains(p))   // and it's not a superseded default
    }
}
