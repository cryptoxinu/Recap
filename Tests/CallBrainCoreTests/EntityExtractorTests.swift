import Testing
import Foundation
@testable import CallBrainCore

@Suite("EntityExtractor (native NaturalLanguage NER)")
struct EntityExtractorTests {

    @Test("extracts people and organizations, counts repeats, ranks by count")
    func extractsAndRanks() {
        let text = """
        Riley said the integration is going well. Riley and Dominic met about it.
        Microsoft shipped the update. Marco joined the call from Google.
        """
        let ents = EntityExtractor.extract(text)
        let names = Set(ents.map(\.name))
        #expect(names.contains("Riley"))
        // Riley appears twice → count >= 2
        let riley = ents.first { $0.name == "Riley" }
        #expect((riley?.count ?? 0) >= 2)
        #expect(riley?.kind == .person)
        // A well-known organization is recognized (Microsoft or Google).
        #expect(ents.contains { $0.kind == .organization })
    }

    @Test("filters junk: lowercase fragments, single chars, numbers, filler words")
    func filtersJunk() {
        #expect(EntityExtractor.extract("the and 42 a").isEmpty)
        // sentence-initial filler that NER mis-capitalizes should be dropped
        let ents = EntityExtractor.extract("Okay. Um. Yeah. So.")
        #expect(!ents.contains { ["Okay", "Um", "Yeah", "So"].contains($0.name) })
    }

    @Test("empty text → no entities")
    func empty() {
        #expect(EntityExtractor.extract("").isEmpty)
    }

    @Test("clean(): merges person spelling variants into the higher-count canonical (Robin/Robyn)")
    func mergesVariants() {
        let raw = [
            Entity(name: "Robin", kind: .person, count: 5),
            Entity(name: "Robyn", kind: .person, count: 2),
            Entity(name: "Dominic", kind: .person, count: 3),
        ]
        let cleaned = EntityExtractor.clean(raw)
        let people = cleaned.filter { $0.kind == .person }.map(\.name)
        #expect(people.contains("Robin"))          // higher count wins
        #expect(!people.contains("Robyn"))          // variant merged away
        #expect(cleaned.first { $0.name == "Robin" }?.count == 7)   // counts summed
        #expect(people.contains("Dominic"))
    }

    @Test("clean(): never merges distinct short names (Sam/Pam), keeps both")
    func keepsDistinctShortNames() {
        let raw = [Entity(name: "Sam", kind: .person, count: 2), Entity(name: "Pam", kind: .person, count: 2)]
        let people = EntityExtractor.clean(raw).map(\.name)
        #expect(people.contains("Sam") && people.contains("Pam"))
    }

    @Test("clean(): drops filler mis-tags (Wait) and tool names as people (Claude)")
    func dropsFillerAndTools() {
        let raw = [
            Entity(name: "Wait", kind: .person, count: 4),
            Entity(name: "Claude", kind: .person, count: 6),
            Entity(name: "Alex", kind: .person, count: 3),
        ]
        let people = EntityExtractor.clean(raw).map(\.name)
        #expect(!people.contains("Wait"))           // sentence-initial filler
        #expect(!people.contains("Claude"))         // a tool, not an attendee
        #expect(people.contains("Alex"))            // a real person survives
    }

    @Test("LIVE: extracts real entities from the morning-sync notes",
          .enabled(if: FileManager.default.fileExists(atPath: DocxReaderTestsPath.realDocx)))
    func liveMorningSync() throws {
        let text = try DocxReader.read(url: URL(fileURLWithPath: DocxReaderTestsPath.realDocx))
        let ents = EntityExtractor.extract(text)
        #expect(!ents.isEmpty)
        print("ENTITIES (\(ents.count)): " + ents.prefix(20).map { "\($0.name)[\($0.kind.rawValue)×\($0.count)]" }.joined(separator: ", "))
    }
}

enum DocxReaderTestsPath {
    static let realDocx =
        "/Users/z/CallBrain/data/raw/google_meet_recordings/morning sync - 2026_06_29 09_29 PDT - Notes by Gemini (1).docx"
}
