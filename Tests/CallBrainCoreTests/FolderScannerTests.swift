import Testing
import Foundation
@testable import CallBrainCore

@Suite("FolderScanner (archive migration)")
struct FolderScannerTests {

    @Test("recursively finds recognized files, skips others + hidden")
    func scan() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cb-scan-\(UUID().uuidString)")
        let sub = root.appendingPathComponent("2026/calls")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func write(_ path: String) throws { try "x".write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8) }
        try write("a.txt")
        try write("b.docx")
        try write("notes.pdf")          // not recognized
        try write(".hidden.txt")        // hidden → skipped
        try "x".write(to: sub.appendingPathComponent("call.srt"), atomically: true, encoding: .utf8)  // nested

        let found = FolderScanner.importableFiles(in: root, recognized: ["txt", "docx", "srt"])
        let names = Set(found.map(\.lastPathComponent))
        #expect(names == ["a.txt", "b.docx", "call.srt"])   // pdf + hidden excluded; nested included
    }

    @Test("empty / missing folder → no crash, empty result")
    func empty() {
        let nope = FileManager.default.temporaryDirectory.appendingPathComponent("cb-missing-\(UUID().uuidString)")
        #expect(FolderScanner.importableFiles(in: nope, recognized: ["txt"]).isEmpty)
    }
}
