import Testing
import Foundation
@testable import CallBrainCore

/// Pure-formatter goldens for the Call Corpus export (B1): the Markdown, JSON, index line, hash
/// stability, slug, and mmss are all deterministic given a fixed input + `exportedAt`.
@Suite("Call corpus formatter")
struct CallCorpusFormatterTests {

    /// A fixed UTC instant so `exported_at` is machine-independent in goldens: 2026-07-02T09:14:33Z.
    private var fixedDate: Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 7; comps.day = 2
        comps.hour = 9; comps.minute = 14; comps.second = 33
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: comps)!
    }

    private var sampleCall: CorpusCall {
        CorpusCall(
            id: "m_0189abcdef123456", title: "Acme Q3 Planning", originalTitle: "GMT-Recording",
            date: "2026-06-30", startTime: "2026-06-30T15:02:11-07:00", durationSeconds: 2571,
            source: "gemini", company: "Acme", category: "further_health", categoryConfidence: 0.82,
            summarySource: "cloud", participants: ["Jordan Lee", "Dana Whitfield"],
            oneLiner: "Aligned on the Q3 plan.", userNotes: "Watch cloud costs.",
            summary: "We reviewed three fronts.",
            actionItems: [
                CorpusActionItem(owner: "Jordan Lee", text: "Send the model", status: "open"),
                CorpusActionItem(owner: nil, text: "Book follow-up", status: "done")
            ],
            transcript: [
                CorpusTurn(t: 0, speaker: "Jordan Lee", inferred: false, text: "Thanks for joining."),
                CorpusTurn(t: 63.1, speaker: "Dana Whitfield", inferred: true, text: "On hiring.")
            ],
            contentHash: "blake3:abc", updatedAt: "2026-06-30 22:41:07")
    }

    @Test("markdown renders every field with correct YAML quoting, checkbox state, and inferred marker")
    func markdownGolden() {
        let call = sampleCall
        let hash = CallCorpusFormatter.exportHash(call)
        let md = CallCorpusFormatter.markdown(call, exportedAt: fixedDate, exportHash: hash)

        #expect(md.hasPrefix("---\nschema_version: 1\nid: m_0189abcdef123456\n"
            + "title: \"Acme Q3 Planning\"\noriginal_title: \"GMT-Recording\"\ndate: 2026-06-30\n"))
        #expect(md.contains("start_time: \"2026-06-30T15:02:11-07:00\"\nduration: \"42:51\"\n"
            + "duration_seconds: 2571\nsource: \"gemini\"\ncompany: \"Acme\"\ncategory: \"further_health\"\n"
            + "category_confidence: 0.82\nsummary_source: \"cloud\"\n"))
        #expect(md.contains("participants:\n  - \"Jordan Lee\"\n  - \"Dana Whitfield\"\n"))
        #expect(md.contains("action_items:\n  - owner: \"Jordan Lee\"\n    text: \"Send the model\"\n"
            + "    status: \"open\"\n  - owner: null\n    text: \"Book follow-up\"\n    status: \"done\"\n"))
        #expect(md.contains("content_hash: \"blake3:abc\"\nexport_hash: \(hash)\n"
            + "exported_at: 2026-07-02T09:14:33Z\n---\n"))
        #expect(md.contains("# Acme Q3 Planning\n\n> Aligned on the Q3 plan.\n"))
        #expect(md.contains("\n## Notes\n_Your own notes, typed during the call._\n\nWatch cloud costs.\n"))
        #expect(md.contains("\n## Summary\n\nWe reviewed three fronts.\n"))
        #expect(md.contains("\n## Action items\n- [ ] **Jordan Lee**: Send the model\n- [x] Book follow-up\n"))
        #expect(md.contains("\n## Transcript\n_source: gemini · 2 speakers · 42:51_\n\n"
            + "**[00:00] Jordan Lee:** Thanks for joining.\n\n"
            + "**[01:03] Dana Whitfield:** _(inferred)_ On hiring.\n\n"))
    }

    @Test("markdown omits absent fields and empty sections")
    func markdownOmission() {
        let bare = CorpusCall(id: "m_xyz000111222", title: "Quick chat", date: "2026-07-01",
                              source: "audio", updatedAt: "u")
        let md = CallCorpusFormatter.markdown(bare, exportedAt: fixedDate,
                                              exportHash: CallCorpusFormatter.exportHash(bare))
        #expect(md.contains("# Quick chat"))
        #expect(!md.contains("original_title:"))
        #expect(!md.contains("company:"))
        #expect(!md.contains("category_confidence:"))
        #expect(!md.contains("participants:"))
        #expect(!md.contains("action_items:"))
        #expect(!md.contains("## Notes"))
        #expect(!md.contains("## Summary"))
        #expect(!md.contains("## Action items"))
        #expect(!md.contains("## Transcript"))
    }

    @Test("exportHash excludes exported_at (stable across export times) and tracks content changes")
    func exportHashStability() {
        let call = sampleCall
        let d1 = Date(timeIntervalSince1970: 1000)
        let d2 = Date(timeIntervalSince1970: 2000)
        // The artifact differs by timestamp…
        #expect(CallCorpusFormatter.json(call, exportedAt: d1) != CallCorpusFormatter.json(call, exportedAt: d2))
        // …but the content hash does not depend on when it was exported.
        #expect(CallCorpusFormatter.exportHash(call) == CallCorpusFormatter.exportHash(call))
        // A real content change flips the hash.
        let changed = CorpusCall(id: call.id, title: call.title, date: call.date, source: call.source,
                                 summary: "A different summary.", updatedAt: call.updatedAt)
        #expect(CallCorpusFormatter.exportHash(changed) != CallCorpusFormatter.exportHash(call))
    }

    @Test("slug folds/collapses/caps and falls back to 'call'")
    func slugRules() {
        #expect(CallCorpusFormatter.slug("Acme Q3 Planning") == "acme-q3-planning")
        #expect(CallCorpusFormatter.slug("  Héllo!!  Wörld  ") == "hello-world")
        #expect(CallCorpusFormatter.slug("🎉🎉") == "call")
        #expect(CallCorpusFormatter.slug("") == "call")
        #expect(CallCorpusFormatter.slug(String(repeating: "a", count: 100)).count <= 60)
    }

    @Test("filenameStem: readable prefix + deterministic 12-hex id hash; unique per id; path-safe date")
    func filenameStemRules() {
        let stem = CallCorpusFormatter.filenameStem(date: "2026-06-30", title: "Acme Q3 Planning",
                                                    id: "m_0189abcdef123456")
        let prefix = "2026-06-30-acme-q3-planning-"
        #expect(stem.hasPrefix(prefix))
        let suffix = stem.dropFirst(prefix.count)
        #expect(suffix.count == 16 && suffix.allSatisfy(\.isHexDigit))
        // Deterministic for the same id…
        #expect(CallCorpusFormatter.filenameStem(date: "2026-06-30", title: "Acme Q3 Planning",
                                                 id: "m_0189abcdef123456") == stem)
        // …and different ids never collide onto the same stem (would overwrite a call's file).
        #expect(CallCorpusFormatter.filenameStem(date: "2026-06-30", title: "Acme Q3 Planning",
                                                 id: "m_different") != stem)
        // A malformed date can't inject a path separator.
        #expect(!CallCorpusFormatter.filenameStem(date: "2026/07/01", title: "x", id: "i").contains("/"))
    }

    @Test("mmss formats mm:ss and h:mm:ss, nil/negative → 00:00")
    func mmssRules() {
        #expect(CallCorpusFormatter.mmss(0) == "00:00")
        #expect(CallCorpusFormatter.mmss(63.1) == "01:03")
        #expect(CallCorpusFormatter.mmss(3661) == "1:01:01")
        #expect(CallCorpusFormatter.mmss(nil) == "00:00")
        #expect(CallCorpusFormatter.mmss(-5) == "00:00")
    }

    @Test("index line is a single snake_case JSON line that round-trips back to the entry")
    func indexRoundTrip() {
        let call = sampleCall
        let entry = CallCorpusFormatter.indexEntry(call, stem: "2026-06-30-acme-q3-planning-123456",
                                                   exportedAt: fixedDate, exportHash: "hh")
        let line = CallCorpusFormatter.indexLine(entry)
        #expect(!line.contains("\n"))
        #expect(line.contains("\"action_item_count\":2"))
        #expect(line.contains("\"export_hash\":\"hh\""))
        #expect(line.contains("\"file\":\"calls/2026-06-30-acme-q3-planning-123456.md\""))
        #expect(CallCorpusFormatter.parseIndexLine(line) == entry)
        #expect(CallCorpusFormatter.parseIndexLine("  ") == nil)
        #expect(CallCorpusFormatter.parseIndexLine("{not json") == nil)
    }

    @Test("non-finite doubles never crash, silently-empty, or corrupt output")
    func nonFiniteSafe() throws {
        #expect(CallCorpusFormatter.mmss(.nan) == "00:00")
        #expect(CallCorpusFormatter.mmss(.infinity) == "00:00")
        let call = CorpusCall(id: "m_nan000111", title: "T", date: "2026-07-01", source: "audio",
                              categoryConfidence: .nan,
                              transcript: [CorpusTurn(t: .infinity, speaker: "A", inferred: false, text: "hi")],
                              updatedAt: "u")
        let data = CallCorpusFormatter.json(call, exportedAt: fixedDate)
        #expect(!data.isEmpty) // never silently empty (that would collide export hashes)
        #expect((try? JSONSerialization.jsonObject(with: data)) != nil) // valid JSON
        #expect(!CallCorpusFormatter.exportHash(call).isEmpty)
        let md = CallCorpusFormatter.markdown(call, exportedAt: fixedDate, exportHash: "h")
        #expect(!md.contains("category_confidence:")) // NaN confidence omitted
        #expect(md.contains("[00:00]")) // infinite turn t → 00:00, no trap
    }

    @Test("hostile title/name/id cannot inject frontmatter keys or terminate the block")
    func frontmatterInjection() {
        let call = CorpusCall(id: "m_x\ninjected: true", title: "Evil\ntitle: fake\nid: hacked",
                              date: "2026-07-01", source: "audio", participants: ["A\nrole: admin"],
                              updatedAt: "u")
        let md = CallCorpusFormatter.markdown(call, exportedAt: fixedDate, exportHash: "hh\nx: y")
        #expect(!md.contains("\ninjected: true")) // id newline stripped
        #expect(!md.contains("\nid: hacked"))      // title newline collapsed inside the quoted scalar
        #expect(!md.contains("\nrole: admin"))     // participant newline collapsed
        #expect(!md.contains("\nx: y"))            // export_hash newline stripped
    }

    @Test("json is structured, snake_case, with null owner and per-turn t_mmss")
    func jsonStructure() throws {
        let data = CallCorpusFormatter.json(sampleCall, exportedAt: fixedDate)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["schema_version"] as? Int == 1)
        #expect(obj["one_liner"] as? String == "Aligned on the Q3 plan.")
        #expect(obj["exported_at"] as? String == "2026-07-02T09:14:33Z")
        #expect((obj["participants"] as? [String]) == ["Jordan Lee", "Dana Whitfield"])
        let turns = try #require(obj["transcript"] as? [[String: Any]])
        #expect(turns.count == 2)
        #expect(turns[1]["t_mmss"] as? String == "01:03")
        #expect(turns[1]["inferred"] as? Bool == true)
        let items = try #require(obj["action_items"] as? [[String: Any]])
        #expect(items[0]["owner"] as? String == "Jordan Lee")
        #expect(items[1]["owner"] == nil) // nil optionals are omitted (clean "null-omitted" JSON)
        #expect(items[0]["status"] as? String == "open")
    }
}
