import Testing
import Foundation
@testable import CallBrainCore

private struct ExplodingSubtitleLLM: LLMProvider {
    let id: ProviderID = .claude

    func complete(prompt: String, system: String?, model: String, timeout: TimeInterval) async throws -> Completion {
        throw LLMError.providerError(subtype: "unexpected_ai", detail: "AI fallback should not run")
    }

    func completeJSON(prompt: String, system: String?, schema: String,
                      model: String, timeout: TimeInterval) async throws -> String {
        throw LLMError.providerError(subtype: "unexpected_ai", detail: "AI fallback should not run")
    }
}

@Suite("Subtitle parser")
struct SubtitleParserTests {

    @Test("parses SRT cues with comma milliseconds and unknown speaker")
    func parsesSRT() throws {
        let srt = """
        1
        00:00:01,500 --> 00:00:03,000
        Hello &amp; welcome.

        2
        00:00:03,250 --> 00:00:04,000
        Second line
        continues.

        3
        00:00:05,000 --> 00:00:06,250
        Final <i>tag</i>.
        """

        let t = try SubtitleParser.parse(srt)
        #expect(t.source == .srtVtt)
        #expect(t.speakers == ["Unknown"])
        #expect(t.utterances.count == 3)
        #expect(t.utterances[0].speakerRaw == "Unknown")
        #expect(t.utterances[0].speakerConfidence == nil)
        #expect(t.utterances[0].tStart == 1.5)
        #expect(t.utterances[0].tEnd == 3.0)
        #expect(t.utterances[0].text == "Hello & welcome.")
        #expect(t.utterances[1].text == "Second line continues.")
        #expect(t.utterances[2].text == "Final tag.")
    }

    @Test("parses VTT voice tags, dot milliseconds, MM:SS timestamps, and merges same speaker")
    func parsesVTTVoiceTagsAndMerges() throws {
        let vtt = """
        WEBVTT

        intro
        00:00.000 --> 00:02.000
        <v Alex>Hello &amp; hi</v>

        00:02.000 --> 00:03.500
        <v Alex>Follow <i>up</i></v>

        00:04.000 --> 00:05.250
        <v Dom>Reply &lt;ok&gt;</v>
        """

        let t = try SubtitleParser.parse(vtt)
        #expect(t.source == .srtVtt)
        #expect(t.speakers == ["Alex", "Dom"])
        #expect(t.utterances.count == 2)
        #expect(t.utterances[0].speakerRaw == "Alex")
        #expect(t.utterances[0].speakerConfidence == 1.0)
        #expect(t.utterances[0].tStart == 0)
        #expect(t.utterances[0].tEnd == 3.5)
        #expect(t.utterances[0].text == "Hello & hi Follow up")
        #expect(t.utterances[1].speakerRaw == "Dom")
        #expect(t.utterances[1].tStart == 4.0)
        #expect(t.utterances[1].tEnd == 5.25)
        #expect(t.utterances[1].text == "Reply <ok>")
    }

    @Test("AIImporter detects SRT/VTT by extension and content")
    func importerDetectsSubtitles() {
        let srt = """
        1
        00:00:01,000 --> 00:00:02,000
        Hi.
        """
        let srtNoMillis = """
        1
        00:00:01 --> 00:00:02
        Hi.
        """
        let vtt = """
        WEBVTT

        00:01.000 --> 00:02.000
        <v Alex>Hi.</v>
        """
        let bomVTT = "\u{FEFF}WEBVTT"

        #expect(AIImporter.detect(srt) == .subtitle)
        #expect(AIImporter.detect(srtNoMillis) == .subtitle)
        #expect(AIImporter.detect(vtt) == .subtitle)
        #expect(AIImporter.detect(bomVTT) == .subtitle)
        #expect(AIImporter.detect("Hi.", fileExtension: "srt") == .subtitle)
        #expect(AIImporter.detect("Hi.", fileExtension: "VTT") == .subtitle)
    }

    @Test("ingestFile routes subtitle extensions into deterministic parsing")
    func ingestFilePassesSubtitleExtensionToImporter() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-subtitle-ext-\(UUID().uuidString).srt")
        try "not a subtitle cue".write(to: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: path) }

        let storePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-subtitle-ext-\(UUID().uuidString).sqlite").path
        let engine = IngestEngine(store: try Store(path: storePath), embedder: StubEmbedder(), space: "stub__v1")
        let importer = AIImporter(llm: ExplodingSubtitleLLM())

        await #expect(throws: ParseError.unrecognizedStructure("Subtitle: no SRT/VTT cues recognized")) {
            _ = try await engine.ingestFile(at: path, importer: importer)
        }
    }

    @Test("empty input throws .empty")
    func emptyThrows() {
        #expect(throws: ParseError.empty) { try SubtitleParser.parse("  \n ") }
    }
}
