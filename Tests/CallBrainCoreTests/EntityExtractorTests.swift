import Testing
import Foundation
@testable import CallBrainCore

@Suite("EntityExtractor (native NaturalLanguage NER)")
struct EntityExtractorTests {

    @Test("extracts people and organizations, counts repeats, ranks by count")
    func extractsAndRanks() {
        let text = """
        Travis said the integration is going well. Travis and Maxwell met about it.
        Microsoft shipped the update. Gregory joined the call from Google.
        """
        let ents = EntityExtractor.extract(text)
        let names = Set(ents.map(\.name))
        #expect(names.contains("Travis"))
        // Travis appears twice → count >= 2
        let travis = ents.first { $0.name == "Travis" }
        #expect((travis?.count ?? 0) >= 2)
        #expect(travis?.kind == .person)
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
