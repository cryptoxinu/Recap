import Foundation
import CallBrainAppCore

/// Chrome Native Messaging host for Recap pairing (Phase 4).
///
/// Chrome launches this binary and connects it ONLY to the extension id listed in the host manifest's
/// `allowed_origins` (an identity the browser guarantees). We read the current loopback token + port
/// from the app-maintained 0600 bridge file and hand them back over the authenticated stdio channel —
/// so the token never transits the spoofable `/pair` HTTP origin check.
///
/// Protocol (per message): read a 4-byte little-endian length + that many UTF-8 JSON bytes from stdin,
/// write one framed JSON response to stdout, exit. We ignore the request body's contents (the extension
/// just needs the token); reading it keeps us a well-behaved host. A single request→response is all
/// `chrome.runtime.sendNativeMessage` performs before closing the pipe.
@main
struct CBPairHost {
    static func main() {
        let stdin = FileHandle.standardInput
        let stdout = FileHandle.standardOutput

        // Consume the incoming message (header + body) so the pipe drains cleanly. A pipe read can return
        // FEWER bytes than asked, so we accumulate to the EXACT lengths; EOF / a malformed or oversized
        // header → respond with an honest error rather than hanging, crashing, or handing over the token
        // on a truncated request.
        guard let header = readExactly(stdin, 4),
              let bodyLen = NativeMessagingProtocol.bodyLength(header: header) else {
            respond(stdout, PairHostResponse.error("no request"))
            return
        }
        if bodyLen > 0, readExactly(stdin, bodyLen) == nil {   // request truncated mid-body → refuse
            respond(stdout, PairHostResponse.error("truncated request"))
            return
        }

        let appSupport = NativeMessagingInstaller.defaultApplicationSupport()
        guard let bridge = NativeMessagingInstaller.readBridge(applicationSupport: appSupport) else {
            respond(stdout, PairHostResponse.error("Recap isn't running, or hasn't been opened since install"))
            return
        }
        respond(stdout, PairHostResponse.ok(token: bridge.token, port: bridge.port))
    }

    private static func respond(_ out: FileHandle, _ body: Data) {
        try? out.write(contentsOf: NativeMessagingProtocol.frame(body))
    }

    /// Read EXACTLY `count` bytes, looping over short pipe reads; nil on EOF before `count` bytes arrive.
    private static func readExactly(_ handle: FileHandle, _ count: Int) -> Data? {
        var buf = Data(); buf.reserveCapacity(count)
        while buf.count < count {
            guard let chunk = try? handle.read(upToCount: count - buf.count), !chunk.isEmpty else { return nil }
            buf.append(chunk)
        }
        return buf
    }
}
