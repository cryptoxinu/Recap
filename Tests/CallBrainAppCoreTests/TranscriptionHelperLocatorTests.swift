import Foundation
import Testing
@testable import CallBrainAppCore

@Suite("Transcription helper locator")
struct TranscriptionHelperLocatorTests {
    @Test("candidate order: executable dir, resource dir, .build/debug, .build/release, launch dir")
    func candidateOrder() {
        let exe = URL(fileURLWithPath: "/Applications/CallBrain.app/Contents/MacOS")
        let res = URL(fileURLWithPath: "/Applications/CallBrain.app/Contents/Resources")
        let cwd = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        let launch = URL(fileURLWithPath: "/tmp/launch")
        let list = TranscriptionHelperLocator.candidates(executableDir: exe, resourceDir: res,
                                                         cwd: cwd, launchDir: launch)
        #expect(list.map(\.path) == [
            exe.appendingPathComponent("cbtranscribe").path,
            res.appendingPathComponent("cbtranscribe").path,
            cwd.appendingPathComponent(".build/debug/cbtranscribe").path,
            cwd.appendingPathComponent(".build/release/cbtranscribe").path,
            launch.appendingPathComponent("cbtranscribe").path,
        ])
    }

    @Test("firstExecutable SKIPS a non-executable earlier candidate for a real one")
    func skipsNonExecutableEarlierCandidate() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-helper-\(UUID().uuidString)", isDirectory: true)
        let earlyDir = base.appendingPathComponent("macos", isDirectory: true)   // executableDir (1st)
        let lateDir = base.appendingPathComponent("resources", isDirectory: true) // resourceDir (2nd)
        for d in [earlyDir, lateDir] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        // Non-executable "cbtranscribe" at the FIRST candidate — must be skipped.
        let notReal = earlyDir.appendingPathComponent("cbtranscribe")
        try "not a real binary".write(to: notReal, atomically: true, encoding: .utf8)
        // A REAL executable at the SECOND candidate.
        let real = lateDir.appendingPathComponent("cbtranscribe")
        try "#!/bin/sh\nexit 0\n".write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: real.path)

        let list = TranscriptionHelperLocator.candidates(executableDir: earlyDir, resourceDir: lateDir,
                                                         cwd: base, launchDir: nil)
        #expect(list.first == notReal)                                   // it IS first in order…
        #expect(TranscriptionHelperLocator.firstExecutable(in: list) == real)  // …but skipped for the executable
    }

    @Test("no candidate exists → nil (never a crash)")
    func missingHelperResolvesNil() {
        let dir = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        let list = TranscriptionHelperLocator.candidates(executableDir: dir, resourceDir: nil,
                                                         cwd: dir, launchDir: nil)
        #expect(TranscriptionHelperLocator.firstExecutable(in: list) == nil)
    }
}
