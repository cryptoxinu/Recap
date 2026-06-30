import Foundation
import CryptoKit

/// Google OAuth 2.0 for a NATIVE/desktop app: Authorization-Code flow with **PKCE** + a **loopback**
/// redirect (`http://127.0.0.1:<port>`), per Google's "OAuth for installed apps". All request builders
/// here are pure + unit-tested; the loopback listener, browser-open, and URLSession calls live elsewhere
/// (`GoogleDriveClient`, app-side `GoogleDriveConnect`). The founder supplies a Desktop-app OAuth client
/// (client id + secret) — see `docs/GOOGLE-DRIVE-SETUP.md`. The "secret" of a desktop client is not truly
/// confidential and is only sent in the token exchange, never embedded in a URL.
public enum GoogleOAuth {
    public static let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    public static let tokenEndpoint = "https://oauth2.googleapis.com/token"
    /// Read-only Drive (list + download the user's own files). `drive.readonly` is a sensitive scope; in
    /// "testing" mode the founder just adds themselves as a test user (no Google app-verification needed).
    public static let driveReadonlyScope = "https://www.googleapis.com/auth/drive.readonly"

    // MARK: - PKCE

    /// A high-entropy code verifier (RFC 7636): 64 random bytes → base64url (43–128 chars). If the system
    /// RNG ever fails, fall back to UUID-derived entropy rather than emitting all-zero bytes (SME LOW).
    public static func makeCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            let fallback = (UUID().uuidString + UUID().uuidString + UUID().uuidString).utf8
            return base64URL(Data(Array(fallback).prefix(64)))
        }
        return base64URL(Data(bytes))
    }

    /// S256 challenge = base64url(SHA256(verifier)).
    public static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// A random opaque `state` to bind the redirect to this request (CSRF defense).
    public static func makeState() -> String { makeCodeVerifier() }

    static func base64URL(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - request builders

    public static func authorizationURL(clientID: String, redirectURI: String, codeChallenge: String,
                                        state: String, scope: String = driveReadonlyScope) -> URL? {
        var c = URLComponents(string: authEndpoint)
        c?.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scope),
            .init(name: "code_challenge", value: codeChallenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),   // ask for a refresh_token
            .init(name: "prompt", value: "consent"),        // ensure a refresh_token is returned
        ]
        return c?.url
    }

    /// Form-encoded body to exchange an auth code for tokens.
    public static func tokenExchangeBody(code: String, clientID: String, clientSecret: String,
                                         redirectURI: String, codeVerifier: String) -> String {
        form([("code", code), ("client_id", clientID), ("client_secret", clientSecret),
              ("redirect_uri", redirectURI), ("grant_type", "authorization_code"),
              ("code_verifier", codeVerifier)])
    }

    /// Form-encoded body to refresh an access token.
    public static func tokenRefreshBody(refreshToken: String, clientID: String, clientSecret: String) -> String {
        form([("refresh_token", refreshToken), ("client_id", clientID),
              ("client_secret", clientSecret), ("grant_type", "refresh_token")])
    }

    static func form(_ pairs: [(String, String)]) -> String {
        var cs = CharacterSet.alphanumerics; cs.insert(charactersIn: "-._~")
        return pairs.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: cs) ?? "")" }
            .joined(separator: "&")
    }

    /// Parse the redirect query (`?code=…&state=…` or `?error=…`) the loopback server captured.
    public static func parseRedirect(query: String) -> (code: String?, state: String?, error: String?) {
        var comps = URLComponents(); comps.query = query
        let items = comps.queryItems ?? []
        func v(_ n: String) -> String? { items.first(where: { $0.name == n })?.value }
        return (v("code"), v("state"), v("error"))
    }

    public struct TokenResponse: Codable, Sendable, Equatable {
        public let access_token: String?     // absent on an error envelope (then `error` is set)
        public let refresh_token: String?
        public let expires_in: Int?
        public let token_type: String?
        public let error: String?
        public let error_description: String?
    }

    /// Parse Google's token response. Throws on an `{"error":…}` envelope or a missing access token, so
    /// callers can rely on a usable token. Returns the access token alongside the full response.
    @discardableResult
    public static func parseTokenResponse(_ data: Data) throws -> TokenResponse {
        let r = try JSONDecoder().decode(TokenResponse.self, from: data)
        if let e = r.error { throw DriveError.oauth("\(e): \(r.error_description ?? "")") }
        guard r.access_token?.isEmpty == false else { throw DriveError.badResponse("token response missing access_token") }
        return r
    }
}

public enum DriveError: Error, Sendable, Equatable {
    case notConfigured                 // no OAuth client id/secret set
    case notConnected                  // no stored refresh token
    case oauth(String)
    case http(status: Int, body: String)
    case badResponse(String)
}
