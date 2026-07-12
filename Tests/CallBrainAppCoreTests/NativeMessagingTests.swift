import Testing
import Foundation
@testable import CallBrainAppCore

/// Phase 4 — Chrome Native Messaging pairing host. Locks the stdio wire framing, the host-manifest
/// shape Chrome parses, and the on-disk bridge the host reads (including its 0600/0700 permissions).
@Suite("Native Messaging pairing host (Phase 4)")
struct NativeMessagingTests {

    // ── wire framing ──
    @Test("frame prefixes a 4-byte little-endian length; bodyLength decodes it back")
    func frameRoundTrip() {
        let body = Data(#"{"ok":true}"#.utf8)
        let framed = NativeMessagingProtocol.frame(body)
        #expect(framed.count == body.count + 4)
        // Little-endian length prefix.
        #expect([UInt8](framed.prefix(4)) == [UInt8(body.count), 0, 0, 0])
        #expect(NativeMessagingProtocol.bodyLength(header: framed.prefix(4)) == body.count)
        #expect(framed.suffix(body.count) == body)
    }

    @Test("bodyLength rejects a wrong-size header and an over-cap length")
    func bodyLengthGuards() {
        #expect(NativeMessagingProtocol.bodyLength(header: Data([1, 2, 3])) == nil)         // too short
        #expect(NativeMessagingProtocol.bodyLength(header: Data([0, 0, 0, 0, 0])) == nil)   // too long
        #expect(NativeMessagingProtocol.bodyLength(header: Data([0, 0, 0, 0])) == 0)        // empty body ok
        // 0xFFFFFFFF (4 GB) far exceeds the 1 MB cap → rejected, never allocated.
        #expect(NativeMessagingProtocol.bodyLength(header: Data([0xff, 0xff, 0xff, 0xff])) == nil)
    }

    // ── response bodies ──
    @Test("ok/error response bodies are the JSON the extension expects")
    func responseBodies() throws {
        let ok = try #require(try JSONSerialization.jsonObject(with: PairHostResponse.ok(token: "T", port: 8422)) as? [String: Any])
        #expect(ok["ok"] as? Bool == true)
        #expect(ok["token"] as? String == "T")
        #expect(ok["port"] as? Int == 8422)
        let err = try #require(try JSONSerialization.jsonObject(with: PairHostResponse.error("nope")) as? [String: Any])
        #expect(err["ok"] as? Bool == false)
        #expect(err["error"] as? String == "nope")
    }

    // ── host manifest ──
    @Test("host manifest carries the pinned extension origin, stdio type, and absolute path")
    func hostManifest() throws {
        let data = NativeMessagingInstaller.hostManifest(hostPath: "/Applications/CallBrain.app/Contents/MacOS/cbpairhost")
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["name"] as? String == "com.callbrain.pair")
        #expect(obj["type"] as? String == "stdio")
        #expect(obj["path"] as? String == "/Applications/CallBrain.app/Contents/MacOS/cbpairhost")
        let origins = try #require(obj["allowed_origins"] as? [String])
        #expect(origins == ["chrome-extension://lcmphiaobpklepliifghlmpdiblkfgpm/"])
    }

    // ── bridge round-trip + permissions ──
    private func tempSupport() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cb-nm-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("writeBridge → readBridge round-trips token+port; file is 0600 in a 0700 dir")
    func bridgeRoundTrip() throws {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let file = try NativeMessagingInstaller.writeBridge(token: "secret-token", port: 8425, applicationSupport: support)

        let back = try #require(NativeMessagingInstaller.readBridge(applicationSupport: support))
        #expect(back.token == "secret-token")
        #expect(back.port == 8425)

        let fm = FileManager.default
        let filePerms = try #require((try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.int16Value)
        #expect(filePerms == 0o600)
        let dirPerms = try #require((try fm.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.int16Value)
        #expect(dirPerms == 0o700)
    }

    @Test("readBridge is nil when the app never wrote one (not running / never paired)")
    func bridgeAbsent() {
        #expect(NativeMessagingInstaller.readBridge(applicationSupport: tempSupport()) == nil)
    }

    @Test("removeBridge clears the on-disk token")
    func bridgeRemoval() throws {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        _ = try NativeMessagingInstaller.writeBridge(token: "t", port: 8422, applicationSupport: support)
        NativeMessagingInstaller.removeBridge(applicationSupport: support)
        #expect(NativeMessagingInstaller.readBridge(applicationSupport: support) == nil)
    }

    // ── target directories: only installed browsers ──
    @Test("installs only into browser families that exist — no stray directories")
    func targetsOnlyExistingBrowsers() throws {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let fm = FileManager.default
        // Chrome present, Arc absent.
        try fm.createDirectory(at: support.appendingPathComponent("Google/Chrome"), withIntermediateDirectories: true)
        let targets = NativeMessagingInstaller.targetDirectories(applicationSupport: support)
        #expect(targets.contains { $0.path.hasSuffix("Google/Chrome/NativeMessagingHosts") })
        #expect(!targets.contains { $0.path.contains("/Arc/") })

        // installHostManifest actually writes the manifest into Chrome's dir.
        let written = NativeMessagingInstaller.installHostManifest(
            hostPath: "/Applications/CallBrain.app/Contents/MacOS/cbpairhost", applicationSupport: support)
        #expect(written.count == 1)
        let manifestPath = support.appendingPathComponent("Google/Chrome/NativeMessagingHosts/com.callbrain.pair.json").path
        #expect(fm.fileExists(atPath: manifestPath))

        // removeHostManifest tears it back down (no dangling manifest when the host binary goes away).
        NativeMessagingInstaller.removeHostManifest(applicationSupport: support)
        #expect(!fm.fileExists(atPath: manifestPath))
    }
}
