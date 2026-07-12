import Foundation

/// One-click "Research attendees with AI" for call prep (2026-07-09). Given an upcoming call's
/// attendees, figure out who ISN'T on the founder's team, resolve each external person to their
/// company by email domain, and build the prompt that the web-research provider runs to produce a
/// quick "who are they / what does their company do / how to prep" briefing.
///
/// Pure over injected data (names + emails + team signal), so it's fully unit-testable and never
/// touches a live calendar or an LLM. It only PREPARES the research request — the app runs it.
public enum AttendeeResearch {

    /// Consumer/free mail domains: an attendee here is an external individual, not a company we can
    /// research from the domain (the domain tells us nothing about who they are).
    public static let freeMailDomains: Set<String> = [
        "gmail.com", "googlemail.com", "yahoo.com", "ymail.com", "hotmail.com", "outlook.com",
        "live.com", "msn.com", "icloud.com", "me.com", "mac.com", "aol.com", "proton.me",
        "protonmail.com", "pm.me", "hey.com", "gmx.com", "fastmail.com", "zoho.com", "qq.com",
    ]

    /// Two-part public suffixes so `team.company.co.uk` → company "Company", not "Co".
    static let twoPartTLDs: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "co.jp", "co.kr", "com.au", "net.au", "org.au",
        "com.br", "com.cn", "com.hk", "com.sg", "co.in", "co.nz", "co.za",
    ]

    public struct Person: Sendable, Equatable {
        public let name: String?      // display name when known
        public let email: String?     // full email when known
        public init(name: String?, email: String?) {
            self.name = name; self.email = email
        }
        public var domain: String? { AttendeeResearch.domain(ofEmail: email) }
        /// The best human label to show/prompt with: the name, else the email local part titlecased.
        public var label: String {
            if let n = name, !n.trimmingCharacters(in: .whitespaces).isEmpty, !n.contains("@") { return n }
            if let local = email?.split(separator: "@").first { return prettify(String(local)) }
            return email ?? "Guest"
        }
    }

    /// External people grouped by their company (email domain). Free-mail / domain-less external
    /// people fall into `individuals` (researched by name, no company).
    public struct Company: Sendable, Equatable, Identifiable {
        public let domain: String
        public let name: String        // prettified company name
        public let people: [Person]
        public var id: String { domain }
    }

    public struct Plan: Sendable, Equatable {
        public let eventTitle: String
        public let companies: [Company]
        public let individuals: [Person]   // external, no resolvable company
        public var hasTargets: Bool { !companies.isEmpty || !individuals.isEmpty }
        /// Distinct external companies — the headline count ("Researching 2 companies").
        public var companyCount: Int { companies.count }
        public var personCount: Int { companies.reduce(0) { $0 + $1.people.count } + individuals.count }
    }

    /// Build the research plan for one event. `teamDomains` are the founder's own org domains (external =
    /// anyone else); a founder-owned email seen among the attendees (local part / name matches an alias)
    /// also contributes its domain to the team set, so a single event self-resolves the team even with no
    /// corpus-derived domains. Names are matched to emails best-effort (local part appears in a name).
    public static func plan(eventTitle: String, names: [String], emails: [String],
                            founderAliases: [String], teamDomains: Set<String>) -> Plan {
        let aliases = founderAliases.map { $0.lowercased() }
        let cleanEmails = emails.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("@") }

        // Effective team domains = passed-in ∪ the domain of any founder-owned email in this event.
        var team = Set(teamDomains.map { $0.lowercased() })
        for e in cleanEmails where isFounderEmail(e, aliases: aliases, names: names) {
            if let d = domain(ofEmail: e) { team.insert(d) }
        }

        // Names that are themselves email addresses are covered by `emails`; drop them from the name pool.
        let namePool = names.filter { !$0.contains("@") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var usedNames = Set<Int>()

        func matchName(for email: String) -> String? {
            guard let local = email.split(separator: "@").first.map({ String($0).lowercased() }) else { return nil }
            let localTokens = Set(local.split { !$0.isLetter }.map(String.init).filter { $0.count > 1 })
            for (i, n) in namePool.enumerated() where !usedNames.contains(i) {
                let nl = n.lowercased()
                let firstTok = nl.split(separator: " ").first.map(String.init) ?? nl
                if localTokens.contains(where: { nl.contains($0) }) || local.hasPrefix(firstTok) || nl.contains(local) {
                    usedNames.insert(i); return n
                }
            }
            return nil
        }

        // External people (those NOT on the team and NOT the founder), grouped by domain.
        var byDomain: [String: [Person]] = [:]
        var individuals: [Person] = []
        var seen = Set<String>()
        for e in cleanEmails {
            guard let d = domain(ofEmail: e) else { continue }
            if team.contains(d) { continue }                                   // teammate
            if isFounderEmail(e, aliases: aliases, names: names) { continue }   // the founder
            guard seen.insert(e).inserted else { continue }                    // dedupe
            let person = Person(name: matchName(for: e), email: e)
            if freeMailDomains.contains(d) { individuals.append(person) }
            else { byDomain[d, default: []].append(person) }
        }

        let companies = byDomain.keys.sorted().map { d in
            Company(domain: d, name: companyName(fromDomain: d),
                    people: byDomain[d]!.sorted { $0.label < $1.label })
        }
        return Plan(eventTitle: eventTitle, companies: companies,
                    individuals: individuals.sorted { $0.label < $1.label })
    }

    /// Derive the founder's team domains from a corpus of attendee emails: the dominant non-free-mail
    /// domain(s). The founder attends nearly every one of their own calls, so their org domain leads.
    /// Returns every domain whose count is ≥ half the top domain's count (handles two work domains).
    public static func deriveTeamDomains(fromEmails emails: [String]) -> Set<String> {
        var counts: [String: Int] = [:]
        for e in emails {
            guard let d = domain(ofEmail: e.lowercased()), !freeMailDomains.contains(d) else { continue }
            counts[d, default: 0] += 1
        }
        guard let top = counts.values.max(), top > 0 else { return [] }
        let floor = max(2, Int((Double(top) * 0.5).rounded()))
        return Set(counts.filter { $0.value >= floor }.keys)
    }

    /// The founder's own org domains, learned from any founder-owned email in a corpus (local part /
    /// name matches a founder alias). This is the PRECISE team signal — unlike frequency derivation it
    /// can't miscategorize a recurring external partner as team — so callers prefer it when non-empty.
    public static func founderDomains(inEmails emails: [String], aliases: [String]) -> Set<String> {
        let al = aliases.map { $0.lowercased() }
        var out = Set<String>()
        for e in emails {
            let lc = e.lowercased()
            if isFounderEmail(lc, aliases: al, names: []), let d = domain(ofEmail: lc) { out.insert(d) }
        }
        return out
    }

    /// The web-research prompt. Instructional (not a question) and explicitly grounded ONLY in the
    /// open web — the injected attendee text is DATA, never instructions (the provider runs with just
    /// WebSearch+WebFetch, no shell/file tools, so it can't be turned into code execution either way).
    public static func prompt(_ plan: Plan) -> String {
        var lines: [String] = []
        lines.append("I have an upcoming call titled \"\(plan.eventTitle)\". Research the EXTERNAL "
            + "people and companies below (they are not on my team) so I can prepare. Use the web.")
        lines.append("")
        for c in plan.companies {
            let who = c.people.map { p -> String in
                if let e = p.email { return p.name.map { "\($0) <\(e)>" } ?? e }
                return p.label
            }.joined(separator: ", ")
            lines.append("- Company \(c.name) (\(c.domain)) — attendee(s): \(who)")
        }
        for p in plan.individuals {
            let who: String
            if let e = p.email { who = p.name.map { "\($0) <\(e)>" } ?? e }
            else { who = p.label }
            lines.append("- Individual: \(who)")
        }
        lines.append("")
        lines.append("""
        For EACH company, give me a tight briefing:
        1. What the company does (one or two sentences) and its stage/size if findable.
        2. The specific person on the call — their role/title and background, if you can identify them \
        from the email and the call title.
        3. Anything recent and notable (funding, launches, news) in the last year.
        4. 2–3 smart, specific talking points or questions I could raise given what I do.
        Keep it skimmable with a short header per company. If you can't confirm something, say so plainly \
        rather than guessing. Do not invent facts, funding, or titles.
        """)
        return lines.joined(separator: "\n")
    }

    /// A STABLE content hash of the plan's research targets (FNV-1a, like PrepPrompt.sourceHash) so a
    /// cached briefing is reused for the same call but invalidated if the external guest list changes.
    /// Deterministic across process runs (Swift's `hashValue` is NOT — it's per-run seeded).
    public static func sourceHash(_ plan: Plan) -> String {
        func field(_ s: String) -> String { "\(s.utf8.count):\(s)\u{1}" }
        var acc = field(plan.eventTitle)
        for c in plan.companies {
            acc += field(c.domain)
            for p in c.people { acc += field(p.email ?? "") + field(p.name ?? "") }
        }
        for p in plan.individuals { acc += field(p.email ?? "") + field(p.name ?? "") }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in acc.utf8 { hash ^= UInt64(byte); hash = hash &* 0x100000001b3 }
        return String(hash, radix: 16)
    }

    // MARK: - helpers

    public static func domain(ofEmail email: String?) -> String? {
        guard let email, let at = email.firstIndex(of: "@") else { return nil }
        let d = email[email.index(after: at)...].lowercased().trimmingCharacters(in: .whitespaces)
        return d.isEmpty ? nil : d
    }

    /// Is this email the founder's own? Its local part or a matched name is a founder alias.
    static func isFounderEmail(_ email: String, aliases: [String], names: [String]) -> Bool {
        guard let local = email.split(separator: "@").first.map({ String($0).lowercased() }) else { return false }
        let tokens = Set(local.split { !$0.isLetter }.map(String.init))
        if aliases.contains(where: { tokens.contains($0) || local == $0 }) { return true }
        return false
    }

    /// "syndicatetrade.org" → "Syndicatetrade"; "team.acme-labs.co.uk" → "Acme-labs".
    static func companyName(fromDomain domain: String) -> String {
        let parts = domain.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return prettify(domain) }
        // Strip a known two-part TLD, else the single last label.
        let lastTwo = parts.suffix(2).joined(separator: ".")
        let core: String
        if twoPartTLDs.contains(lastTwo), parts.count >= 3 { core = parts[parts.count - 3] }
        else { core = parts[parts.count - 2] }
        return prettify(core)
    }

    static func prettify(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        guard let f = t.first else { return t }
        return f.uppercased() + t.dropFirst()
    }
}
