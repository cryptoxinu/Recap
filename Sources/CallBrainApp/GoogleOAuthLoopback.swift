import Foundation
import AppKit
import CallBrainCore

/// Calendar initiative C4 — the reusable loopback-OAuth runner, extracted from the Drive
/// connect flow so Calendar (and any future Google scope) shares ONE audited handshake:
/// PKCE + state check + 127.0.0.1 redirect + browser + 5-minute timeout. Returns the
/// refresh token, or nil with no side effects.
struct GoogleOAuthLoopback {
    let clientID: String
    let clientSecret: String
    let scope: String

    func run() async -> String? {
        let server = LoopbackServer()
        do {
            let verifier = GoogleOAuth.makeCodeVerifier()
            let challenge = GoogleOAuth.codeChallenge(for: verifier)
            let state = GoogleOAuth.makeState()
            let port = try await server.start()
            let redirect = "http://127.0.0.1:\(port)"
            guard let authURL = GoogleOAuth.authorizationURL(clientID: clientID, redirectURI: redirect,
                                                             codeChallenge: challenge, state: state,
                                                             scope: scope),
                  NSWorkspace.shared.open(authURL) else { server.cancel(); return nil }
            let (code, gotState) = try await withThrowingTaskGroup(of: (code: String, state: String).self) { group in
                group.addTask {
                    try await withTaskCancellationHandler { try await server.waitForCode() }
                    onCancel: { server.cancel() }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(300))
                    server.cancel()
                    throw DriveError.oauth("timed out waiting for Google sign-in")
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw DriveError.oauth("sign-in cancelled") }
                return first
            }
            guard gotState == state else { server.cancel(); return nil }
            // Exchange the code for tokens.
            var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = GoogleOAuth.tokenExchangeBody(code: code, clientID: clientID,
                                                         clientSecret: clientSecret,
                                                         redirectURI: redirect,
                                                         codeVerifier: verifier).data(using: .utf8)
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let refresh = obj["refresh_token"] as? String else { return nil }
            return refresh
        } catch {
            server.cancel()
            return nil
        }
    }
}
