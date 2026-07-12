import Foundation
import CallBrainCore

/// Calendar initiative C4 — DIRECT Google Calendar (for Google accounts NOT added to macOS
/// Calendar). Rides the same keychain-stored OAuth client the Drive integration uses, with the
/// read-only calendar scope. Dormant until the founder configures OAuth creds (same pattern as
/// Drive): `ifConfigured()` returns nil and the hub simply doesn't list the source.
final class GoogleCalendarSource: CalendarSource, @unchecked Sendable {
    let kind = CalendarEvent.SourceKind.google
    static let scope = "https://www.googleapis.com/auth/calendar.readonly"
    static let keychainService = "com.callbrain.app.googlecalendar"
    static let legacyKeychainKey = "refresh-token"

    /// One connected Google account = one keychain refresh token. Multi-account (founder:
    /// "I don't see add gmail accounts") — key is "refresh-token:<email>"; the pre-multi
    /// legacy key has no email until `resolveEmailIfNeeded()` migrates it.
    struct Account: Sendable, Hashable, Identifiable {
        let keychainKey: String
        let email: String?
        var id: String { keychainKey }
        var display: String { email ?? "Google account" }

        static func key(for email: String) -> String { "refresh-token:\(email)" }
    }

    /// Founder: "I linked my Google calendar and nothing showed up" — every failure was silent.
    /// Each fetch records an honest, actionable status here (shown in the calendars popover).
    private let statusLock = NSLock()
    private var _lastStatus: String?
    private(set) var lastStatus: String? {
        get { statusLock.lock(); defer { statusLock.unlock() }; return _lastStatus }
        set { statusLock.lock(); defer { statusLock.unlock() }; _lastStatus = newValue }
    }
    private static let legacyDefaultsKey = "callbrain.gcal.refreshToken"

    private let clientID: String
    private let clientSecret: String
    /// account + tokenStore mutate together during legacy-email migration, which runs
    /// DETACHED while the main actor reads them — same lock discipline as lastStatus.
    private let stateLock = NSLock()
    private var _account: Account
    private var _tokenStore: KeychainSecret
    private(set) var account: Account {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _account }
        set { stateLock.lock(); defer { stateLock.unlock() }; _account = newValue }
    }
    /// Keychain, not UserDefaults (gate HIGH: a refresh token is a credential).
    private var tokenStore: KeychainSecret {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _tokenStore }
        set { stateLock.lock(); defer { stateLock.unlock() }; _tokenStore = newValue }
    }

    init(clientID: String, clientSecret: String, account: Account) {
        self.clientID = clientID; self.clientSecret = clientSecret
        self._account = account
        self._tokenStore = KeychainSecret(service: Self.keychainService, account: account.keychainKey)
    }

    /// Every connected account found in the keychain. Also sweeps the one-time legacy
    /// UserDefaults migration (pre-gate builds left the token in defaults).
    /// "pending-" keys are accounts whose email resolution failed at connect time — they
    /// work (token is valid) and resolve to their real email on a later probe.
    static func storedAccounts() -> [Account] {
        if let legacy = UserDefaults.standard.string(forKey: legacyDefaultsKey) {
            _ = KeychainSecret(service: keychainService, account: legacyKeychainKey).save(legacy)
            UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
        }
        return KeychainSecret.accounts(service: keychainService).compactMap { key in
            if key == legacyKeychainKey { return Account(keychainKey: key, email: nil) }
            guard key.hasPrefix("refresh-token:") else { return nil }
            let suffix = String(key.dropFirst("refresh-token:".count))
            return Account(keychainKey: key, email: suffix.hasPrefix("pending-") ? nil : suffix)
        }
    }

    private var refreshToken: String? {
        get { tokenStore.load() }
        set {
            if let newValue { _ = tokenStore.save(newValue) } else { _ = tokenStore.delete() }
        }
    }

    func availability() async -> Bool? {
        refreshToken == nil ? nil : true
    }

    /// Legacy / pending tokens don't know their email — ask Google for the primary calendar
    /// id (= the account email) and migrate the token under its proper key. If that key
    /// already exists (the same account was ALSO connected explicitly — audit MED), the
    /// redundant token is deleted and this source adopts the existing identity; the hub
    /// dedupes sources afterwards.
    func resolveEmailIfNeeded() async {
        guard account.email == nil, let access = await accessToken() else { return }
        guard let email = await Self.primaryEmail(access: access), !email.isEmpty else { return }
        let newKey = Account.key(for: email)
        let newStore = KeychainSecret(service: Self.keychainService, account: newKey)
        if newStore.load() != nil {
            _ = tokenStore.delete()   // same account already connected — drop the duplicate token
        } else {
            guard let token = refreshToken, newStore.save(token) else { return }
            _ = tokenStore.delete()
        }
        tokenStore = newStore
        account = Account(keychainKey: newKey, email: email)
    }

    /// True when the stored sign-in was actually removed (audit LOW: report failures).
    @discardableResult
    func disconnect() -> Bool {
        tokenStore.delete()
    }

    /// Loopback OAuth for a NEW account: local server catches the redirect, exchanges the
    /// code, resolves the account email (primary calendar id), stores the token per-account.
    /// Returns the connected account, or nil (the flow reports nothing — caller sets status).
    static func connectNewAccount(clientID: String, clientSecret: String) async -> Account? {
        let flow = GoogleOAuthLoopback(clientID: clientID, clientSecret: clientSecret, scope: scope)
        guard let token = await flow.run() else { return nil }
        let account: Account
        if let access = await fetchAccessToken(refresh: token, clientID: clientID, clientSecret: clientSecret),
           let email = await primaryEmail(access: access), !email.isEmpty {
            account = Account(keychainKey: Account.key(for: email), email: email)
        } else {
            // Email resolution failed (offline mid-connect, etc.) — store under a
            // collision-proof pending key, NEVER the legacy slot (audit HIGH: that would
            // silently overwrite an existing account's token). Resolves on a later probe.
            account = Account(keychainKey: "refresh-token:pending-\(UUID().uuidString)", email: nil)
        }
        guard KeychainSecret(service: keychainService, account: account.keychainKey).save(token) else {
            return nil
        }
        return account
    }

    /// The calendarList entry with `primary: true` — its id IS the account email.
    private static func primaryEmail(access: String) async -> String? {
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList?maxResults=250")!)
        req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = obj["items"] as? [[String: Any]] else { return nil }
        return items.first { ($0["primary"] as? Bool) == true }?["id"] as? String
    }

    func events(from: Date, to: Date) async -> [CalendarEvent] {
        guard let access = await accessToken() else {
            if refreshToken != nil { lastStatus = "Google sign-in expired — reconnect." }
            return []
        }
        let iso = ISO8601DateFormatter()
        var out: [CalendarEvent] = []
        for calID in await calendarIDs(access: access) {
            var pageToken: String? = nil
            var pages = 0
            repeat {   // full pagination (gate MED: 250-cap silently dropped events)
            pages += 1
            var comps = URLComponents(string:
                "https://www.googleapis.com/calendar/v3/calendars/\(calID.id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? calID.id)/events")!
            comps.queryItems = [
                .init(name: "timeMin", value: iso.string(from: from)),
                .init(name: "timeMax", value: iso.string(from: to)),
                .init(name: "singleEvents", value: "true"),
                .init(name: "maxResults", value: "250"),
            ]
            if let pageToken { comps.queryItems?.append(.init(name: "pageToken", value: pageToken)) }
            guard let url = comps.url else { break }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = obj["items"] as? [[String: Any]] else { break }
            pageToken = obj["nextPageToken"] as? String
            for it in items {
                guard let id = it["id"] as? String,
                      let startObj = it["start"] as? [String: Any],
                      let endObj = it["end"] as? [String: Any] else { continue }
                let allDay = startObj["date"] != nil
                let start = (startObj["dateTime"] as? String).flatMap { iso.date(from: $0) }
                    ?? (startObj["date"] as? String).flatMap { Self.ymdDate($0) }
                let end = (endObj["dateTime"] as? String).flatMap { iso.date(from: $0) }
                    ?? (endObj["date"] as? String).flatMap { Self.ymdDate($0) }
                guard let start, let end else { continue }
                let rawAttendees = (it["attendees"] as? [[String: Any]]) ?? []
                var attendees = rawAttendees
                    .compactMap { $0["displayName"] as? String ?? ($0["email"] as? String)?.components(separatedBy: "@").first }
                // Keep the FULL emails (domain intact) for attendee research (the display list above
                // strips the domain). Skip resource rooms (`resource: true`).
                var attendeeEmails = rawAttendees
                    .filter { ($0["resource"] as? Bool) != true }
                    .compactMap { ($0["email"] as? String)?.lowercased() }
                    .filter { $0.contains("@") }
                if let org = (it["organizer"] as? [String: Any]) {
                    if let name = org["displayName"] as? String ?? (org["email"] as? String)?.components(separatedBy: "@").first,
                       !attendees.contains(name) { attendees.append(name) }   // organizer counts (gate LOW)
                    if let oe = (org["email"] as? String)?.lowercased(), oe.contains("@"),
                       !attendeeEmails.contains(oe) { attendeeEmails.append(oe) }
                }
                // Conference URL: hangoutLink, else conferenceData's video entry point.
                let hangout = (it["hangoutLink"] as? String)
                    ?? ((it["conferenceData"] as? [String: Any]).flatMap { conf in
                        (conf["entryPoints"] as? [[String: Any]])?
                            .first { ($0["entryPointType"] as? String) == "video" }?["uri"] as? String
                    })
                out.append(CalendarEvent(stableID: id, sourceKind: .google,
                                         calendarName: calID.name,
                                         title: (it["summary"] as? String) ?? "Untitled event",
                                         start: start, end: end,
                                         attendees: attendees, attendeeEmails: attendeeEmails, isAllDay: allDay,
                                         location: it["location"] as? String,
                                         notes: it["description"] as? String,
                                         url: hangout,
                                         isReadOnly: true))   // direct-Google is read-only this pass
            }
            } while pageToken != nil && pages < 20   // hard page cap — never loop forever
        }
        return out
    }

    func calendarNames() async -> [String] {
        guard let access = await accessToken() else { return [] }
        return await calendarIDs(access: access).map(\.name)
    }

    private func calendarIDs(access: String) async -> [(id: String, name: String)] {
        var out: [(id: String, name: String)] = []
        var pageToken: String? = nil
        var pages = 0
        repeat {   // paginated (gate MED)
            pages += 1
            var comps = URLComponents(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")!
            if let pageToken { comps.queryItems = [.init(name: "pageToken", value: pageToken)] }
            guard let url = comps.url else { break }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
            guard let (data, resp) = try? await URLSession.shared.data(for: req) else {
                lastStatus = "Couldn't reach Google — check your connection."; break
            }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                lastStatus = code == 403
                    ? "Google Calendar API isn't enabled for your OAuth project — enable it at console.cloud.google.com → APIs & Services."
                    : "Google returned \(code) listing calendars."
                break
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = obj["items"] as? [[String: Any]] else { break }
            pageToken = obj["nextPageToken"] as? String
            out += items.compactMap { it in
                guard let id = it["id"] as? String else { return nil }
                return (id, (it["summaryOverride"] as? String) ?? (it["summary"] as? String) ?? id)
            }
        } while pageToken != nil && pages < 10
        return out
    }

    /// Protocol conformance — multi-account connects go through `connectNewAccount`; an
    /// instance is only ever constructed for an already-stored account.
    func connect() async -> Bool {
        await availability() == true
    }

    private func accessToken() async -> String? {
        guard let refresh = refreshToken else { return nil }
        return await Self.fetchAccessToken(refresh: refresh, clientID: clientID,
                                           clientSecret: clientSecret)
    }

    static func fetchAccessToken(refresh: String, clientID: String, clientSecret: String) async -> String? {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = GoogleOAuth.tokenRefreshBody(refreshToken: refresh, clientID: clientID,
                                                    clientSecret: clientSecret).data(using: .utf8)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["access_token"] as? String else { return nil }
        return token
    }

    static func ymdDate(_ ymd: String) -> Date? {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; df.locale = Locale(identifier: "en_US_POSIX")
        return df.date(from: ymd)
    }
}
