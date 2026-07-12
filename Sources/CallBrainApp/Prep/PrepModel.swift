import SwiftUI
import CallBrainCore

/// Calendar v4 — per-event call-prep state. Loads the FREE continuation context instantly
/// (no LLM), reads any cached AI brief, and streams a fresh grounded brief on demand. One
/// instance per prep card (owned as @State).
@MainActor
@Observable
final class PrepModel {

    enum Phase: Equatable { case idle, loading, ready, generating, done, refused, failed }

    struct Citation: Identifiable, Equatable, Codable {
        let tag: String; let meetingID: String; let chunkID: String
        let summary: String; let tStart: Double?
        var id: String { tag }
    }

    private(set) var context: CallPrep.Context?
    private(set) var phase: Phase = .idle
    private(set) var streamingText = ""     // live tokens while generating
    private(set) var briefMD: String?       // the finished brief (cached or just-generated)
    private(set) var steps: [AskEngine.ReasoningStep] = []
    private(set) var citations: [Citation] = []
    private(set) var errorText: String?
    private(set) var template: PrepPrompt.Template = .brief

    /// The instant, free brief from the deterministic context (shown before/without AI).
    var deterministicBrief: String { context.map(PrepPrompt.deterministicBrief) ?? "" }
    var hasContent: Bool { context?.hasContent ?? false }

    // One counter guards ALL async writes (load + generate): a stale continuation checks it
    // before touching state (audit HIGH/MED: template switch + overlapping load races).
    private var genCounter = 0
    private var activeTask: Task<Void, Never>?
    /// The in-flight semantic-context gather — cancelled on the next load so a reloaded/dismissed prep card
    /// stops its (potentially full-corpus) vector scan instead of running it to completion (audit MED).
    private var gatherTask: Task<CallPrep.Context, Never>?

    /// Gather free context off-main and load any cached brief for the current template.
    /// Called from PrepCard's `.task(id: event.id)` — which fires on first appear AND when a
    /// reused card's event changes. It therefore FULLY RESETS every time (audit HIGH: an
    /// early `guard phase == .idle` made an event A→B switch a no-op, so B showed A's brief
    /// and A's in-flight generate could write into B's card).
    func load(event: CalendarEvent, env: AppEnvironment) async {
        activeTask?.cancel()
        gatherTask?.cancel()   // stop a previous in-flight vector scan (audit MED)
        genCounter &+= 1
        let gen = genCounter
        briefMD = nil; streamingText = ""; steps = []; citations = []; errorText = nil; context = nil
        phase = .loading
        let store = env.store
        let search = env.search
        // Semantic-augmented gather (prep FIX 6) — the embed + all GRDB reads run OFF the main thread;
        // degrades to lexical matches if the embedder is down. Stored so the next load cancels this scan.
        let task = Task.detached { await PrepGather.context(event: event, store: store, search: search) }
        gatherTask = task
        let ctx = await task.value
        guard gen == genCounter else { return }
        context = ctx
        // Cached brief still valid for this template + current source hash?
        if ctx.hasContent {
            let hash = PrepPrompt.sourceHash(ctx)
            let eid = event.id, tmpl = template.rawValue
            let cached = await Task.detached {
                try? store.prep(eventID: eid, template: tmpl, sourceHash: hash)
            }.value
            guard gen == genCounter else { return }
            if let cached {
                briefMD = cached.briefMD
                // Restore citations so cached briefs keep tappable [S#] chips (audit MED).
                if let json = cached.citationsJSON, let data = json.data(using: .utf8),
                   let cites = try? JSONDecoder().decode([Citation].self, from: data) {
                    citations = cites
                }
                // Re-arm the prep-ready nudge with the CURRENT start (idempotent per event) so
                // a rescheduled event's notification updates on next view (final-audit MED).
                if event.start > Date() {
                    NotificationManager.schedulePrepReady(eventID: event.id, title: event.title, start: event.start)
                }
                phase = .done; return
            }
        }
        phase = .ready
    }

    /// Switch template atomically (invalidates any in-flight work) and reload the cache.
    func setTemplate(_ t: PrepPrompt.Template, event: CalendarEvent, env: AppEnvironment) async {
        guard t != template else { return }
        activeTask?.cancel()
        template = t
        await reset(event: event, env: env)
    }

    /// Regenerate from scratch (Regenerate / template switch) — load() already fully resets.
    func reset(event: CalendarEvent, env: AppEnvironment) async {
        await load(event: event, env: env)
    }

    /// Kick off generation as the tracked active task (cancels any prior run — audit MED).
    func startGenerate(event: CalendarEvent, env: AppEnvironment, web: Bool) {
        activeTask?.cancel()
        activeTask = Task { await generate(event: event, env: env, web: web) }
    }

    /// Stream a grounded AI brief over the prior calls. `web` folds in live web research.
    func generate(event: CalendarEvent, env: AppEnvironment, web: Bool) async {
        guard let ctx = context, ctx.hasContent else { return }
        genCounter &+= 1
        let gen = genCounter
        phase = .generating
        streamingText = ""; steps = []; citations = []; errorText = nil

        // Capture the template NOW — a switch mid-stream must not change the query or the
        // cache key this run writes under (audit HIGH).
        let tmpl = template
        let query = PrepPrompt.query(context: ctx, template: tmpl)
        let meetingIDs = ctx.meetingIDs

        let onStep: AskEngine.StepHandler = { @MainActor [weak self] step in
            guard let self, self.genCounter == gen else { return }
            withAnimation(.snappy) { self.steps.append(step) }
        }
        let onSources: AskEngine.SourcesHandler = { @MainActor [weak self] refs in
            guard let self, self.genCounter == gen else { return }
            self.citations = refs.map {
                Citation(tag: $0.tag, meetingID: $0.meetingID, chunkID: $0.chunkID,
                         summary: "\($0.speaker ?? "Unknown") — \($0.text.prefix(80))…", tStart: $0.tStart)
            }
        }
        let acc = TokenAccumulator()
        let onToken: AskEngine.TokenHandler = { t in await acc.append(t) }
        let drain = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled, self.genCounter == gen else { return }
                let chunk = await acc.drain()
                if !chunk.isEmpty { self.streamingText += chunk }
            }
        }
        defer { drain.cancel() }

        do {
            let ans: AskEngine.Answer
            if web {
                // Scoped-web: call evidence stays hard-scoped to the prior calls (audit HIGH)
                // while the researcher adds live web context on the people/company.
                ans = try await env.ask.research(query, inMeetings: meetingIDs,
                                                 planOverride: QueryPlan(mode: .general), onStep: onStep)
            } else {
                // Explicit .general plan: the prep query is an INSTRUCTION, not a question — bypass
                // date/mode inference so it uses the deep model with no false date-scope (prep-audit HIGH).
                ans = try await env.ask.ask(query, inMeetings: meetingIDs,
                                            planOverride: QueryPlan(mode: .general),
                                            onStep: onStep, onToken: onToken, onSources: onSources)
            }
            drain.cancel()
            _ = await acc.drain()
            guard genCounter == gen else { return }
            if ans.status == .noSources {
                // Ground truth said nothing usable — fall back to the free deterministic brief
                // rather than showing a bare refusal.
                briefMD = PrepPrompt.deterministicBrief(ctx)
                phase = .refused
                return
            }
            let finalCites: [Citation] = ans.citations.map {
                Citation(tag: $0.tag, meetingID: $0.meetingID, chunkID: $0.chunkID,
                         summary: "\($0.speaker ?? "Unknown") — \($0.text.prefix(80))…", tStart: $0.tStart)
            }
            citations = finalCites
            briefMD = ans.text
            phase = .done
            // Granola-style: once a brief exists for an UPCOMING call, schedule a one-off
            // "prep ready" nudge ~30 min before it (no-op if notifications are off / past).
            if event.start > Date() {
                NotificationManager.schedulePrepReady(eventID: event.id, title: event.title, start: event.start)
            }
            // Cache off-main (best-effort) under the template captured at generate start,
            // WITH citations so a restored brief keeps tappable chips (audit MED).
            let store = env.store
            let hash = PrepPrompt.sourceHash(ctx)
            let eid = event.id, tmplRaw = tmpl.rawValue, text = ans.text, model = ans.model
            let citesJSON = (try? JSONEncoder().encode(finalCites)).flatMap { String(data: $0, encoding: .utf8) }
            Task.detached { try? store.savePrep(eventID: eid, template: tmplRaw, sourceHash: hash,
                                                briefMD: text, model: model, citationsJSON: citesJSON) }
        } catch is CancellationError {
            return   // superseded by a newer run — leave state to the winner
        } catch {
            guard genCounter == gen else { return }
            errorText = "Couldn't generate a brief — \(error.localizedDescription)"
            phase = .failed
        }
    }
}
