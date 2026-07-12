import SwiftUI
import CallBrainCore

/// Calendar prep — "Research attendees with AI" (2026-07-09). For a call whose external guests we
/// don't yet know (the "first call with these people" case), identify who isn't on the team, resolve
/// each to their company by email domain, and run a web-research briefing so the founder walks in
/// prepared. One instance per prep card (owned as @State). Uses the same audited web-research path as
/// the prep brief (`AskEngine.research`, WebSearch+WebFetch only, no call grounding here).
@MainActor
@Observable
final class AttendeeResearchModel {

    enum Phase: Equatable { case idle, researching, done, failed, unavailable }

    private(set) var phase: Phase = .idle
    private(set) var plan: AttendeeResearch.Plan?
    private(set) var briefMD: String?
    private(set) var steps: [AskEngine.ReasoningStep] = []
    private(set) var errorText: String?

    private var genCounter = 0
    private var activeTask: Task<Void, Never>?
    private var sourceHash = ""
    /// Cached in the shared `event_prep` table under this reserved template key (attendee research is a
    /// per-event, source-hash-invalidated brief — the same shape as a prep brief).
    nonisolated private static let cacheTemplate = "__attendee_research__"

    /// External targets exist (someone worth researching) — gates the "Research attendees" button.
    var hasTargets: Bool { plan?.hasTargets ?? false }

    /// Build the research plan from the event's attendees (pure string work) AND load any cached briefing
    /// so a previously-researched call shows instantly on relaunch/rebuild — no repeat web pass. Fully
    /// RESETS when the event/guest-set changes (a reused card must never show a prior event's brief —
    /// audit HIGH), and every async write is generation-guarded so a superseded read can't land.
    func prepare(event: CalendarEvent, env: AppEnvironment) async {
        let p = AttendeeResearch.plan(eventTitle: event.title,
                                      names: event.attendees, emails: event.attendeeEmails,
                                      founderAliases: FounderIdentity.aliases,
                                      teamDomains: TeamDomains.current())
        let newHash = AttendeeResearch.sourceHash(p)
        // Event or guest list changed → cancel any in-flight run and clear the old brief before we load.
        if newHash != sourceHash {
            activeTask?.cancel()
            genCounter &+= 1
            briefMD = nil; phase = .idle; steps = []; errorText = nil
            sourceHash = newHash
        }
        plan = p
        let gen = genCounter
        guard p.hasTargets, phase == .idle, briefMD == nil else { return }
        let store = env.store, eid = event.id, h = newHash
        let cached = await Task.detached {
            try? store.prep(eventID: eid, template: Self.cacheTemplate, sourceHash: h)
        }.value
        // Generation guard: a newer prepare()/research() superseded this read while it ran.
        guard gen == genCounter, phase == .idle, briefMD == nil, let cached else { return }
        briefMD = cached.briefMD
        phase = .done
    }

    func start(event: CalendarEvent, env: AppEnvironment) {
        activeTask?.cancel()
        activeTask = Task { await research(event: event, env: env) }
    }

    private func research(event: CalendarEvent, env: AppEnvironment) async {
        guard let plan, plan.hasTargets else { return }
        // Local-only mode disables all web egress → attendee research can't run. Say so honestly.
        if UserDefaults.standard.bool(forKey: AppEnvironment.localOnlyKey) {
            phase = .unavailable
            errorText = "Turn off Local-only mode in Settings to research attendees online."
            return
        }
        genCounter &+= 1
        let gen = genCounter
        // Snapshot the event id + source hash NOW, before the web await — so if the card switches events
        // mid-request, the result is saved/shown under the RIGHT event, never the new one (audit HIGH).
        let eid = event.id, hash = sourceHash
        phase = .researching
        steps = []; errorText = nil; briefMD = nil

        let onStep: AskEngine.StepHandler = { @MainActor [weak self] step in
            guard let self, self.genCounter == gen else { return }
            withAnimation(.snappy) { self.steps.append(step) }
        }
        let query = AttendeeResearch.prompt(plan)
        do {
            // No call grounding: scope call-evidence to the EMPTY set so nothing from prior calls is
            // pulled in — this is a pure open-web briefing on the external people/companies.
            let ans = try await env.ask.research(query, inMeetings: [],
                                                 planOverride: QueryPlan(mode: .general), onStep: onStep)
            guard genCounter == gen else { return }
            let text = ans.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                phase = .failed
                errorText = "Couldn't find anything on these attendees online."
                return
            }
            briefMD = text
            phase = .done
            // Persist under the SNAPSHOTTED event id + hash (not the possibly-changed current ones) so a
            // stale result can't be saved as valid for a different call. Survives restart/rebuild/teardown.
            let store = env.store, model = ans.model
            Task.detached {
                try? store.savePrep(eventID: eid, template: Self.cacheTemplate, sourceHash: hash,
                                    briefMD: text, model: model)
            }
        } catch is CancellationError {
            return
        } catch {
            guard genCounter == gen else { return }
            errorText = "Couldn't research attendees — \(error.localizedDescription)"
            phase = .failed
        }
    }
}
