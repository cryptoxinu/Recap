import Testing
import Foundation
@testable import CallBrainCore

@Suite("IngestEngine.readText (encoding + size guards)")
struct ReadTextTests {

    private func tmp(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cb-read-\(UUID().uuidString).\(ext)")
    }

    @Test("UTF-8 text reads through")
    func utf8() throws {
        let url = tmp("txt"); defer { try? FileManager.default.removeItem(at: url) }
        try "Riley: Render pricing dropped — nice.".write(to: url, atomically: true, encoding: .utf8)
        #expect(try IngestEngine.readText(at: url).contains("Render"))
    }

    @Test("non-UTF-8 (Windows-1252 curly apostrophe 0x92) still reads, no cryptic error (audit H1)")
    func windows1252() throws {
        let url = tmp("srt"); defer { try? FileManager.default.removeItem(at: url) }
        // "it’s render" with a CP1252 right-single-quote (0x92) — invalid UTF-8.
        var bytes: [UInt8] = Array("it".utf8); bytes.append(0x92); bytes.append(contentsOf: Array("s render".utf8))
        try Data(bytes).write(to: url)
        let text = try IngestEngine.readText(at: url)
        #expect(text.contains("render"))
        #expect(!text.isEmpty)
    }

    @Test("a file past the size ceiling is rejected before reading (audit H2)")
    func tooLarge() throws {
        let url = tmp("txt"); defer { try? FileManager.default.removeItem(at: url) }
        // Sparse-write one byte past the ceiling so we don't actually allocate 64 MB.
        let fh = FileManager.default
        fh.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(IngestEngine.maxReadBytes) + 1)
        try handle.close()
        #expect(throws: ReadError.self) { _ = try IngestEngine.readText(at: url) }
    }
}
