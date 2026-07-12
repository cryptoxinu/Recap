import Foundation

/// Chrome Native Messaging support (Phase 4 — pairing hardening).
///
/// The loopback `/pair` route authorizes the token handoff on the request's `Origin` header, which a
/// local process can trivially spoof. Chrome Native Messaging closes that gap: Chrome itself launches
/// our host binary and connects it ONLY to the extension id listed in the host manifest's
/// `allowed_origins` — an identity the browser guarantees, not a spoofable header. So the pairing token
/// is delivered to the extension over Chrome's authenticated stdio channel; a website or a rogue
/// extension can't obtain it this way. The loopback data plane is unchanged, still gated by the same
/// bearer token — native messaging only hardens how that token reaches the pinned extension.
///
/// This file holds the PURE, testable pieces: the stdio wire framing and the manifest/bridge builders.
/// Filesystem installation lives in `NativeMessagingInstaller`.

// MARK: - Wire framing

/// Chrome's Native Messaging wire format: a 4-byte message length in NATIVE byte order (little-endian
/// on every Mac Recap runs on) followed by the UTF-8 JSON body. Both directions use the same frame.
public enum NativeMessagingProtocol {

    /// Chrome caps a single host→browser message at 1 MB; anything larger is a protocol error, never us
    /// (we only ever send `{ok, token, port}`). Guards a corrupt/hostile length prefix from allocating.
    public static let maxMessageBytes = 1_024 * 1_024

    /// Frame a JSON body for stdout: 4-byte little-endian length prefix + the body. Enforces the same
    /// 1 MB cap the decoder does — a body over the cap (never our own tiny responses) is replaced with a
    /// short error so the length prefix can never disagree with the appended bytes (no stream desync).
    public static func frame(_ body: Data) -> Data {
        let body = body.count <= maxMessageBytes ? body : PairHostResponse.error("oversize")
        let n = UInt32(body.count)
        var out = Data(capacity: body.count + 4)
        out.append(UInt8(n & 0xff))
        out.append(UInt8((n >> 8) & 0xff))
        out.append(UInt8((n >> 16) & 0xff))
        out.append(UInt8((n >> 24) & 0xff))
        out.append(body)
        return out
    }

    /// Decode a 4-byte little-endian length header into the expected body length. nil if the header
    /// isn't exactly 4 bytes or the declared length exceeds the 1 MB cap (malformed / hostile input).
    public static func bodyLength(header: Data) -> Int? {
        let bytes = [UInt8](header)
        guard bytes.count == 4 else { return nil }
        let n = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
        let length = Int(n)
        guard length >= 0, length <= maxMessageBytes else { return nil }
        return length
    }
}

// MARK: - Bridge payload (app → host → extension)

/// What the host hands the extension: the current loopback token + bound port, or an honest error when
/// Recap isn't running / hasn't bound a port yet. The host reads `token`/`port` from the on-disk
/// bridge the app maintains — it never touches the Keychain, so it works under ad-hoc and Developer-ID
/// signing alike. (The token is already shared with the extension and persisted unencrypted in Chrome's
/// own profile once paired, so a 0600 bridge file is not a new exposure class.)
public struct PairBridgePayload: Codable, Sendable, Equatable {
    public let token: String
    public let port: Int
    public init(token: String, port: Int) { self.token = token; self.port = port }
}

public enum PairHostResponse {
    /// Success response body for the extension: `{"ok":true,"token":…,"port":…}`.
    public static func ok(token: String, port: Int) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["ok": true, "token": token, "port": port]))
            ?? Data(#"{"ok":false,"error":"encode"}"#.utf8)
    }
    /// Failure response body: `{"ok":false,"error":…}`.
    public static func error(_ message: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["ok": false, "error": message]))
            ?? Data(#"{"ok":false,"error":"unknown"}"#.utf8)
    }
}
