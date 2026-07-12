import Testing
import Foundation
@testable import CallBrainCore

@Suite("AttendeeResearch (who's on the call + company resolution)")
struct AttendeeResearchTests {

    let aliases = ["alex", "sam"]

    @Test("external guest is resolved to their company by domain; teammate + founder excluded")
    func externalResolved() {
        let plan = AttendeeResearch.plan(
            eventTitle: "Sam and Andrew Zinkovskyi",
            names: ["andrew@syndicatetrade.org", "alex@acme.example"],
            emails: ["andrew@syndicatetrade.org", "alex@acme.example"],
            founderAliases: aliases,
            teamDomains: [])   // team self-derived from alex@acme.example
        #expect(plan.companies.count == 1)
        #expect(plan.companies.first?.domain == "syndicatetrade.org")
        #expect(plan.companies.first?.name == "Syndicatetrade")
        #expect(plan.personCount == 1)   // only Andrew — the founder is excluded
    }

    @Test("teammates on the same org domain are NOT external")
    func teammatesExcluded() {
        let plan = AttendeeResearch.plan(
            eventTitle: "Ambient standup",
            names: [], emails: ["alex@acme.example", "dom@acme.example", "riley@acme.example"],
            founderAliases: aliases, teamDomains: ["acme.example"])
        #expect(!plan.hasTargets)
    }

    @Test("free-mail guests become individuals, not companies")
    func freemailIndividuals() {
        let plan = AttendeeResearch.plan(
            eventTitle: "Intro call",
            names: ["Jane Doe"], emails: ["jane.doe@gmail.com", "alex@acme.example"],
            founderAliases: aliases, teamDomains: ["acme.example"])
        #expect(plan.companies.isEmpty)
        #expect(plan.individuals.count == 1)
        #expect(plan.individuals.first?.name == "Jane Doe")   // matched by local part "jane"
    }

    @Test("two external companies both surface, sorted, deduped")
    func twoCompanies() {
        let plan = AttendeeResearch.plan(
            eventTitle: "Partnership sync",
            names: [],
            emails: ["a@syndicatetrade.org", "b@syndicatetrade.org", "c@privy.io", "alex@acme.example"],
            founderAliases: aliases, teamDomains: ["acme.example"])
        #expect(plan.companies.map(\.domain) == ["privy.io", "syndicatetrade.org"])
        #expect(plan.companies.first(where: { $0.domain == "syndicatetrade.org" })?.people.count == 2)
    }

    @Test("two-part TLD resolves the real company label")
    func twoPartTLD() {
        #expect(AttendeeResearch.companyName(fromDomain: "team.acme-labs.co.uk") == "Acme-labs")
        #expect(AttendeeResearch.companyName(fromDomain: "syndicatetrade.org") == "Syndicatetrade")
    }

    @Test("team domains derive from the dominant non-free-mail domain in a corpus")
    func deriveTeam() {
        let emails = ["alex@acme.example", "dom@acme.example", "riley@acme.example",
                      "guest@othercorp.com", "friend@gmail.com"]
        let team = AttendeeResearch.deriveTeamDomains(fromEmails: emails)
        #expect(team.contains("acme.example"))
        #expect(!team.contains("othercorp.com"))   // 1 occurrence < floor
        #expect(!team.contains("gmail.com"))        // free-mail excluded
    }

    @Test("founder's own domain is learned precisely from their identity email")
    func founderDomainsPrecise() {
        let emails = ["alex@acme.example", "andrew@syndicatetrade.org", "friend@gmail.com"]
        let d = AttendeeResearch.founderDomains(inEmails: emails, aliases: aliases)
        #expect(d == ["acme.example"])   // only the founder's domain, not the external partner's
    }

    @Test("sourceHash is stable, deterministic, and changes when the guest list changes (cache key)")
    func sourceHashStableAndInvalidates() {
        let a = AttendeeResearch.plan(eventTitle: "Sync", names: [],
            emails: ["andrew@syndicatetrade.org", "alex@acme.example"],
            founderAliases: aliases, teamDomains: ["acme.example"])
        let h1 = AttendeeResearch.sourceHash(a)
        let h2 = AttendeeResearch.sourceHash(a)
        #expect(h1 == h2)                              // deterministic within a run
        #expect(!h1.isEmpty)
        // A different external guest → different hash → cache correctly invalidates.
        let b = AttendeeResearch.plan(eventTitle: "Sync", names: [],
            emails: ["different@otherco.com", "alex@acme.example"],
            founderAliases: aliases, teamDomains: ["acme.example"])
        #expect(AttendeeResearch.sourceHash(b) != h1)
        // Same targets, different event title → different hash (title is part of the brief).
        let c = AttendeeResearch.plan(eventTitle: "Other Sync", names: [],
            emails: ["andrew@syndicatetrade.org", "alex@acme.example"],
            founderAliases: aliases, teamDomains: ["acme.example"])
        #expect(AttendeeResearch.sourceHash(c) != h1)
    }

    @Test("the prompt names the company + attendee and forbids fabrication")
    func promptShape() {
        let plan = AttendeeResearch.plan(
            eventTitle: "Sam and Andrew Zinkovskyi",
            names: [], emails: ["andrew@syndicatetrade.org", "alex@acme.example"],
            founderAliases: aliases, teamDomains: [])
        let p = AttendeeResearch.prompt(plan)
        #expect(p.contains("Syndicatetrade"))
        #expect(p.contains("andrew@syndicatetrade.org"))
        #expect(p.contains("Sam and Andrew Zinkovskyi"))
        #expect(p.lowercased().contains("do not invent"))
    }
}
