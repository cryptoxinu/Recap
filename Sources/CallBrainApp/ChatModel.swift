import SwiftUI
import CallBrainCore
import CallBrainAppCore

/// Backs a chat surface and PERSISTS every turn to the Store (Phase 4.5), so the conversation shows up in
/// "Recents" and reopening it restores the full thread + citations. A `meetingID` scopes it to a single
/// call's AskFred (retrieval is hard-filtered to that meeting); nil is the global Ask surface.
@MainActor
@Observable
final class ChatModel {
    var messages: [AskMessage] = []
    var recents: [Conversation] = []
    /// convID → one-line last-answer preview for the Recents rail (Task 7.5).
    var recentSnippets: [String: String] = [:]
    var busy = false
    var saveFailed = false                  // true if a turn couldn't be persisted (shown in the UI)
    private(set) var conversationID: String?
    let meetingID: String?
    /// The in-flight generation Task. The turn LIFECYCLE (generation tokens, phase, stop/delta
    /// races) is owned by `ChatReducer` (perfection Task 3.1 — the ONE central guard; Codex
    /// phase-3 HIGH: the reducer must be the production authority, not a test-only artifact).
    /// This class stays the imperative shell: it translates reducer effects into Tasks and
    /// projects reducer state onto the `messages` array.
    private var task: Task<Void, Never>?
    private(set) var chat = ChatReducer.State()
    /// The current generation token — always the reducer's.
    private var generation: Int { chat.generation }

    init(meetingID: String? = nil) { self.meetingID = meetingID }

    /// Fire-and-forget a question — returns immediately; the answer streams into `messages` in the
    /// background and survives view teardown. Ignored if a generation is already running (the
    /// reducer's `.send` guard — never a second CLI).
    func send(_ text: String, _ env: AppEnvironment, research: Bool = false) {
        let fx = ChatReducer.reduce(&chat, .send(question: text))
        guard case .startAsk(let gen)? = fx.first else { return }
        let q = chat.lastQuestion ?? text
        task = Task { [weak self] in await self?.ask(q, env, research: research, gen: gen) }
    }

    /// Stop the current generation (kills the CLI subprocess via Task cancellation) and finalize the
    /// half-written turn so the UI doesn't sit on a spinner. The reducer orphans the cancelled
    /// generation, so its late events (deltas, completion, errors) are dead on arrival.
    func stop() {
        let partial = chat.streamedText
        let fx = ChatReducer.reduce(&chat, .stop)
        guard fx.contains(where: { if case .cancelAsk = $0 { return true }; return false }) else { return }
        task?.cancel(); task = nil; busy = false
        if let i = messages.firstIndex(where: { $0.pending }) {
            messages[i].pending = false
            if partial.isEmpty || partial == "Thinking…" {
                messages[i].text = "_Stopped._"
            } else {
                // The partial streamed BEFORE the citation-validation gate ran — strip its [S#]
                // markers (and clear any source cards) so a stopped draft can't imply grounding
                // that was never verified (audit A HIGH). Marked as an unverified draft.
                let raw = partial.replacingOccurrences(of: #"\s*\[S\d+\]"#, with: "",
                                                       options: .regularExpression)
                messages[i].text = raw + "\n\n_Stopped early — unverified draft._"
                messages[i].citations = []
            }
            messages[i].status = "stopped"
        }
    }

    /// Monotonic sequence for Recents reloads — a slower earlier read can't clobber a newer one
    /// (last-issued wins, not last-completer; audit MED: overlapping off-main refreshes race).
    @ObservationIgnored private var recentsSeq = 0
    /// Serializes retry's persisted-tail read/delete preflight before the generation task exists.
    @ObservationIgnored private var retryPreparing = false

    /// Reload the Recents rail. The Store read runs OFF the main thread (Store is thread-safe) so opening
    /// the Ask tab or finishing an answer never blocks the UI; the result is assigned back on the main actor.
    func refreshRecents(_ env: AppEnvironment) {
        let store = env.store, mid = meetingID
        recentsSeq += 1; let seq = recentsSeq
        Task { [weak self] in
            let (r, snips) = await Task.detached { () -> ([Conversation], [String: String]) in
                let convs = mid == nil ? ((try? store.globalConversations()) ?? [])
                                       : ((try? store.conversations(meetingID: mid!)) ?? [])
                let snips = (try? store.conversationSnippets(ids: convs.map(\.id))) ?? [:]
                return (convs, snips)
            }.value
            guard let self, self.recentsSeq == seq else { return }   // a newer refresh superseded this one
            self.recents = r
            self.recentSnippets = snips
        }
    }

    /// Abandon the in-flight turn — starting a new chat or switching threads discards the current answer:
    /// cancel the CLI subprocess, clear busy/task, and orphan the generation via the reducer so any
    /// in-flight persist or answer write bails instead of clobbering the new thread (audit HIGH).
    private func abandonInFlight() {
        // .invalidate, not .stop — it bumps the generation even when IDLE, so a slow prior
        // load() holding the old token can never overwrite the new thread (round-2 HIGH).
        _ = ChatReducer.reduce(&chat, .invalidate)
        task?.cancel(); task = nil; busy = false; retryPreparing = false
    }

    func newChat() { abandonInFlight(); messages = []; conversationID = nil }

    /// Open a saved conversation. The messages read + mapping happen off-main, so tapping a Recents row
    /// never freezes the UI on a large thread. Messages clear immediately (no stale previous-thread flash),
    /// and the async assign is generation-guarded so a rapid second selection can't land out of order.
    func load(_ conv: Conversation, _ env: AppEnvironment) {
        abandonInFlight()
        conversationID = conv.id
        messages = []
        let gen = generation
        let store = env.store, cid = conv.id
        Task { [weak self] in
            let rows = await Task.detached { (try? store.messages(conversationID: cid)) ?? [] }.value
            guard let self, self.generation == gen else { return }   // superseded by another load/newChat/send
            self.messages = rows.map { m in
                // N-tagged rows are persisted near-misses (gate MED) — route them back to the
                // navigation chips, not the source cards.
                let all = m.citations.map {
                    Cite(tag: $0.tag, meetingID: $0.meetingID, chunkID: $0.chunkID,
                         summary: "\($0.speaker ?? "Unknown") — \($0.text.prefix(80))…",
                         tStart: $0.tStart)
                }
                let cites = all.filter { !$0.tag.hasPrefix("N") }
                let failed = m.role == .assistant && m.provider == Store.failedTurnProviderMarker
                var msg = AskMessage(role: m.role == .user ? .user : .assistant, text: m.text,
                           citations: cites,
                           status: m.role == .assistant ? (failed ? "failed" : (cites.isEmpty ? "no cited moments" : "\(cites.count) cited moments")) : nil)
                msg.nearMisses = failed ? [] : all.filter { $0.tag.hasPrefix("N") }
                msg.steps = failed ? [] : m.steps                       // reasoning survives reload (v12)
                msg.provider = failed ? nil : m.provider.flatMap(ProviderID.init(rawValue:))
                return msg
            }
        }
    }

    func rename(_ id: String, to title: String, _ env: AppEnvironment) {
        let store = env.store
        Task { [weak self] in
            await AppEnvironment.loggedWrite("renameConversation") { try store.renameConversation(id: id, title: title) }
            self?.refreshRecents(env)
        }
    }
    func delete(_ id: String, _ env: AppEnvironment) {
        let store = env.store
        if conversationID == id { newChat() }
        Task { [weak self] in
            await AppEnvironment.loggedWrite("deleteConversation") { try store.deleteConversation(id: id) }
            self?.refreshRecents(env)
        }
    }

    func ask(_ text: String, _ env: AppEnvironment, research requested: Bool = false, gen explicitGen: Int? = nil,
             skipUserPersist: Bool = false) async {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let gen: Int
        if let explicitGen {
            gen = explicitGen
        } else {
            let fx = ChatReducer.reduce(&chat, .send(question: q))
            guard case .startAsk(let g)? = fx.first else { return }   // reducer says busy → no second CLI
            gen = g
        }
        // Round-2 HIGH: a Stop can land between send() scheduling this Task and it starting —
        // never mark busy or append bubbles for an already-orphaned generation.
        guard generation == gen, !Task.isCancelled else { return }
        busy = true
        defer { if generation == gen { busy = false; task = nil } }   // only if still the current turn (H3)
        // Web research is a global-chat capability (the per-call AskFred stays scoped to that call).
        let useResearch = meetingID == nil && (requested || AskEngine.looksLikeResearch(q))

        // Capture the primary AS OF this turn's dispatch, so a mid-flight Settings flip can't mislabel
        // the fallback badge (Phase-5 audit MED).
        let askPrimary = env.providerPrimary
        // Conversation continuity: feed the prior turns (before this question) back into the engine, so a
        // follow-up ("dig into that", "what about the other call") keeps context across the thread.
        let history: [AskEngine.Turn] = messages.compactMap { m in
            guard !m.pending, !m.text.isEmpty, m.status != "failed", m.status != "stopped" else { return nil }
            let hint = m.role == .assistant && !m.citations.isEmpty
                ? m.citations.prefix(6).map { "\($0.tag) \($0.summary)" }.joined(separator: " | ")
                : nil
            return AskEngine.Turn(role: m.role == .user ? .user : .assistant,
                                  text: m.text, retrievalHint: hint)
        }

        // Show the user's bubble + the "Thinking…" placeholder IMMEDIATELY (pure in-memory, no DB) so the
        // submit feels instant — the durable persistence below runs entirely off the main thread.
        withAnimation(.snappy) { messages.append(AskMessage(role: .user, text: q, citations: [])) }
        let pending = AskMessage(role: .assistant, text: "Thinking…", citations: [], pending: true)
        withAnimation(.snappy) { messages.append(pending) }
        let pid = pending.id

        // Ensure a conversation exists (auto-titled from the first question), then persist the user turn —
        // both OFF-MAIN and serialized (conversation row before its messages, FK-safe). nil = couldn't
        // persist; the chat still works in-memory but we DON'T pretend it's saved (Codex P4.5 gate HIGH).
        let convID = await ensureConversation(firstQuestion: q, env, gen: gen)
        if Task.isCancelled || generation != gen { return }   // abandoned during the conversation upsert
        // On a retry the user turn is ALREADY persisted from the first (failed) attempt — don't write it
        // again, or reopening the thread shows a duplicate "You" row (audit HIGH).
        if !skipUserPersist, let convID { await persist(.user, text: q, citations: [], conversationID: convID, env) }

        // Live reasoning timeline: append each real pipeline step to the pending message.
        let onStep: AskEngine.StepHandler = { @MainActor [weak self] step in
            guard let self, let i = self.messages.firstIndex(where: { $0.id == pid }) else { return }
            withAnimation(.snappy) { self.messages[i].steps.append(step) }
        }

        // Sources-first (Task 3.4): retrieval lands in ms — show the source cards immediately so
        // the generation wait reads as proof, not a spinner. Replaced by the validated cited set
        // when the answer completes.
        let onSources: AskEngine.SourcesHandler = { @MainActor [weak self] refs in
            guard let self else { return }
            ChatReducer.reduce(&self.chat, .sourcesArrived(generation: gen, count: refs.count))
            guard self.chat.generation == gen, self.chat.sourcesCount != nil,
                  let i = self.messages.firstIndex(where: { $0.id == pid }) else { return }
            withAnimation(.snappy) {
                self.messages[i].citations = refs.map {
                    Cite(tag: $0.tag, meetingID: $0.meetingID, chunkID: $0.chunkID,
                         summary: "\($0.speaker ?? "Unknown") — \($0.text.prefix(80))…", tStart: $0.tStart)
                }
                self.messages[i].status = "\(refs.count) retrieved moments"
            }
        }

        // Token stream, coalesced: deltas accumulate OFF-main; a ~30Hz main-actor drain appends
        // them to the bubble (per-token main-thread churn is the historical freeze shape).
        let acc = TokenAccumulator()
        let onToken: AskEngine.TokenHandler = { t in await acc.append(t) }
        // 100ms flush (~10Hz): still reads as live, and each flush is a full CoreAnimation
        // commit — an in-stall sample (2026-07-02) showed the only remaining smoke stalls were
        // the COMPOSITOR waiting on render-surface allocation under model-loaded memory
        // pressure (RenderBox wait_for_allocations; zero Recap frames), so fewer commits =
        // less back-pressure. History: 33ms animated follows caused a real 3.4s stall.
        // Deltas flow through the REDUCER; the bubble projects `chat.streamedText`, so a stale
        // chunk that wakes after stop/finish mutates nothing (Codex phase-3 HIGH: the old
        // `text += chunk` could append after the final text was assigned).
        let drain = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled else { return }
                let chunk = await acc.drain()
                // An empty tick is a normal LULL (model thinking, or before the first token) — keep
                // draining, don't kill the task. The old `else { return }` exited on the first empty
                // tick, so live streaming froze at the first pause mid-answer (audit G1 HIGH).
                if chunk.isEmpty { continue }
                if Task.isCancelled { return }
                ChatReducer.reduce(&self.chat, .delta(generation: gen, text: chunk))
                guard self.chat.generation == gen, self.chat.phase == .streaming,
                      let i = self.messages.firstIndex(where: { $0.id == pid }) else { continue }
                self.messages[i].text = self.chat.streamedText
            }
        }
        defer { drain.cancel() }

        do {
            let ans: AskEngine.Answer
            if useResearch {
                ans = try await env.ask.research(q, history: history, onStep: onStep)
            } else if meetingID == nil {
                ans = try await env.ask.ask(q, history: history, onStep: onStep,
                                            onToken: onToken, onSources: onSources)
            } else {
                ans = try await env.ask.ask(q, inMeeting: meetingID!, history: history, onStep: onStep,
                                            onToken: onToken, onSources: onSources)
            }
            drain.cancel()
            // Flush any tail the drain didn't get to before the final text replaces everything.
            _ = await acc.drain()
            // The reducer is the gate: a stale generation's .finished produces no effects (H3).
            let finishFx = ChatReducer.reduce(&chat, .finished(
                generation: gen, finalText: ans.text,
                cited: ans.status == .answered, provider: ans.provider?.rawValue))
            guard finishFx.contains(.persistTurn) else { return }
            if Task.isCancelled { return }
            if let m = ans.metrics {   // Phase-0 telemetry: append off-main; never blocks the answer
                Task.detached(priority: .utility) { m.appendToLog() }
            }
            let cites = ans.citations.map {
                Cite(tag: $0.tag, meetingID: $0.meetingID, chunkID: $0.chunkID,
                     summary: "\($0.speaker ?? "Unknown") — \($0.text.prefix(80))…",
                     tStart: $0.tStart)
            }
            if let i = messages.firstIndex(where: { $0.id == pid }) {
                withAnimation(.snappy) {
                    messages[i].text = ans.text
                    messages[i].citations = cites
                    messages[i].pending = false
                    messages[i].status = ans.status == .answered ? "\(cites.count) cited moments" : "no cited moments"
                    messages[i].provider = ans.provider
                    // Honest per-answer fallback flag: TRUE only when a non-primary engine actually
                    // answered this turn — not a comparison against the CURRENT setting (which used to
                    // retro-badge every old answer the moment you flipped the primary in Settings).
                    messages[i].fellBack = ans.provider != nil && askPrimary != nil
                        && ans.provider != askPrimary
                    messages[i].followUps = ans.followUps
                    messages[i].nearMisses = ans.nearMisses.map {
                        Cite(tag: $0.tag, meetingID: $0.meetingID, chunkID: $0.chunkID,
                             summary: "\($0.speaker ?? "Unknown") — \($0.text.prefix(80))…",
                             tStart: $0.tStart)
                    }
                }
            }
            // Near-misses ride citations_json with their N-prefix tags, so a reloaded refusal
            // keeps its navigation chips (gate MED).
            let stored = (ans.citations + ans.nearMisses).map {
                StoredCitation(tag: $0.tag, chunkID: $0.chunkID, meetingID: $0.meetingID,
                               speaker: $0.speaker, text: $0.text, tStart: $0.tStart)
            }
            if let convID {
                let steps = messages.first(where: { $0.id == pid })?.steps ?? []
                await persist(.assistant, text: ans.text, citations: stored, conversationID: convID, env,
                              steps: steps, provider: ans.provider?.rawValue)
                autoTitleIfFirstAnswer(convID: convID, question: q, answer: ans.text, env)
            }
            refreshRecents(env)
        } catch {
            if Task.isCancelled { return }
            let friendly = Self.friendlyFailure(error)
            ChatReducer.reduce(&chat, .failed(generation: gen, message: friendly))
            guard chat.failureMessage == friendly, chat.generation == gen else { return }  // stale turn
            if let i = messages.firstIndex(where: { $0.id == pid }) {
                messages[i].text = friendly
                messages[i].pending = false
                messages[i].status = "failed"      // AskMessageView renders this as an error, not an answer
                messages[i].steps = []             // a failed turn didn't "reason" to an answer — clear the timeline
                messages[i].citations = []         // and it has no cited moments
            }
            // Keep the persisted thread structurally complete after reload: user row + failed assistant row.
            // The marker lets retry replace this row instead of treating it as a successful answer.
            if let convID {
                await persist(.assistant, text: friendly, citations: [], conversationID: convID, env,
                              provider: Store.failedTurnProviderMarker)
                refreshRecents(env)
            }
        }
    }

    /// Map an Ask failure to plain-language copy — a missing CLI / stopped Ollama / offline user should see
    /// a friendly, actionable line, never a developer-flavored `localizedDescription`.
    static func friendlyFailure(_ error: Error) -> String {
        if let llm = error as? LLMError {
            switch llm {
            case .notInstalled, .launchFailed, .allProvidersFailed:
                return "Couldn't reach the AI engine — check Engine status on the Home screen."
            case .rateLimited:
                return "Rate limited — try again shortly."
            case .timedOut:
                return "That took too long to answer. Try again."
            default:
                break
            }
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {   // offline / connection dropped mid-research
            return "Couldn't reach the AI engine — check your connection and try again."
        }
        return "Couldn't reach the AI engine — check Engine status on the Home screen."
    }

    private struct RetryTarget {
        let question: String
        let shouldDeleteFailedAssistant: Bool
        let skipUserPersist: Bool
    }

    /// The durable retry target is the persisted tail: either a user row with no following assistant, or a
    /// failed assistant marker with its preceding user. A successful assistant tail is deliberately a no-op.
    private static func retryTarget(persistedMessages rows: [Message]) -> RetryTarget? {
        guard let last = rows.last else { return nil }
        if last.role == .user {
            return RetryTarget(question: last.text, shouldDeleteFailedAssistant: false, skipUserPersist: true)
        }
        guard last.provider == Store.failedTurnProviderMarker,
              let user = rows[..<rows.index(before: rows.endIndex)].last(where: { $0.role == .user })
        else { return nil }
        return RetryTarget(question: user.text, shouldDeleteFailedAssistant: true, skipUserPersist: true)
    }

    /// Session-local fallback for an unsaved failed turn. Persisted conversations use the store as authority.
    private static func retryTarget(visibleMessages rows: [AskMessage], skipUserPersist: Bool) -> RetryTarget? {
        guard let last = rows.last else { return nil }
        if last.role == .user {
            return RetryTarget(question: last.text, shouldDeleteFailedAssistant: false, skipUserPersist: skipUserPersist)
        }
        guard last.role == .assistant, last.status == "failed",
              let user = rows.dropLast().last(where: { $0.role == .user })
        else { return nil }
        return RetryTarget(question: user.text, shouldDeleteFailedAssistant: false, skipUserPersist: skipUserPersist)
    }

    private func trimVisibleRetryTail(question: String) {
        if let aIdx = messages.lastIndex(where: { $0.role == .assistant && $0.status == "failed" }),
           let uIdx = messages[..<aIdx].lastIndex(where: { $0.role == .user && $0.text == question }) {
            messages = Array(messages[..<uIdx])
        } else if let last = messages.last, last.role == .user, last.text == question {
            messages = Array(messages.dropLast())
        }
    }

    /// Retry the MOST RECENT failed or unanswered persisted turn. The store tail is authoritative, so a failed
    /// turn still retries after app relaunch; successful answered tails stay a no-op.
    func retryLast(_ env: AppEnvironment) {
        guard task == nil, !retryPreparing else { return }
        retryPreparing = true
        let store = env.store
        let cid = conversationID
        let startGeneration = generation
        Task { [weak self] in
            defer { self?.retryPreparing = false }
            guard let self, self.task == nil, self.generation == startGeneration,
                  self.conversationID == cid else { return }
            let target: RetryTarget?
            if let cid {
                let persisted = await Task.detached { try? store.messages(conversationID: cid) }.value
                if let persisted, !persisted.isEmpty {
                    let persistedTarget = Self.retryTarget(persistedMessages: persisted)
                    target = persistedTarget ?? (self.messages.count > persisted.count
                        ? Self.retryTarget(visibleMessages: self.messages, skipUserPersist: false) : nil)
                } else if persisted != nil {
                    target = Self.retryTarget(visibleMessages: self.messages, skipUserPersist: false)
                } else {
                    self.saveFailed = true
                    return
                }
            } else {
                target = Self.retryTarget(visibleMessages: self.messages, skipUserPersist: false)
            }
            guard let target,
                  !target.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  self.task == nil, self.generation == startGeneration,
                  self.conversationID == cid else { return }
            if target.shouldDeleteFailedAssistant, let cid {
                let ok = await AppEnvironment.loggedWrite("deleteLastAssistantMessage") {
                    try store.deleteLastAssistantMessage(conversationID: cid)
                }
                guard ok, self.task == nil, self.generation == startGeneration,
                      self.conversationID == cid else {
                    if !ok { self.saveFailed = true }
                    return
                }
            }
            self.trimVisibleRetryTail(question: target.question)
            let fx = ChatReducer.reduce(&self.chat, .send(question: target.question))
            guard case .startAsk(let gen)? = fx.first else { return }
            self.task = Task { [weak self] in
                await self?.ask(target.question, env, gen: gen, skipUserPersist: target.skipUserPersist)
            }
        }
    }

    /// Regenerate the MOST RECENT successful answer with a fresh generation (Task 4.4) — same
    /// tail surgery as retryLast but without the failed-only guard; the user turn stays persisted.
    /// The OLD answer's persisted row is deleted too, or a reload would resurrect it beside the
    /// regenerated one (round-2 MED: memory and store must agree).
    func regenerate(_ env: AppEnvironment) {
        guard task == nil else { return }
        guard let aIdx = messages.lastIndex(where: { $0.role == .assistant }), !messages[aIdx].pending,
              aIdx > 0, messages[aIdx - 1].role == .user else { return }
        let question = messages[aIdx - 1].text
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        messages.removeSubrange((aIdx - 1)...)
        let fx = ChatReducer.reduce(&chat, .send(question: question))
        guard case .startAsk(let gen)? = fx.first else { return }
        let convID = conversationID
        task = Task { [weak self] in
            // AWAIT the old row's deletion BEFORE the new ask persists (round-3 + phase-4 HIGH:
            // deleteLastAssistantMessage removes the NEWEST assistant row — if the regenerated
            // answer won the race it was the one deleted, diverging store from memory).
            if let convID {
                let store = env.store
                await AppEnvironment.loggedWrite("deleteLastAssistantMessage") { try store.deleteLastAssistantMessage(conversationID: convID) }
            }
            await self?.ask(question, env, gen: gen, skipUserPersist: true)
        }
    }

    // MARK: - persistence

    /// Create the conversation row (OFF-MAIN — Store is thread-safe); return its id ONLY if the insert
    /// succeeded (else nil + flag the failure, so we never show a "saved" chat that silently vanishes on
    /// relaunch — gate HIGH). Awaited before any message persist so the FK (messages→conversation) holds.
    private func ensureConversation(firstQuestion q: String, _ env: AppEnvironment, gen: Int) async -> String? {
        if let id = conversationID { return id }
        let id = "conv_" + UUID().uuidString
        let now = Date().timeIntervalSince1970
        let conv = Conversation(id: id, title: Self.title(from: q), meetingID: meetingID, createdAt: now, updatedAt: now)
        let store = env.store
        let ok = await Task.detached {
            do { try store.upsertConversation(conv); return true } catch { return false }
        }.value
        // Re-validate after the suspension: if the user started a new chat or opened another thread while
        // the upsert was in flight, DON'T clobber the model's conversationID — roll the orphan row back
        // instead of binding this turn to a conversation the user abandoned (audit HIGH: reentrancy race).
        guard generation == gen, conversationID == nil else {
            // Roll back the orphan row — but ONLY if it wasn't adopted as the current conversation in the
            // meantime (a recents refresh could have surfaced it and load() bound to it); audit MED.
            if conversationID != id { Task.detached { try? store.deleteConversation(id: id) } }
            return nil
        }
        if ok { conversationID = id; return id }
        saveFailed = true
        return nil
    }

    private func persist(_ role: Message.Role, text: String, citations: [StoredCitation],
                         conversationID: String, _ env: AppEnvironment,
                         steps: [AskEngine.ReasoningStep] = [], provider: String? = nil) async {
        let msg = Message(id: "msg_" + UUID().uuidString, conversationID: conversationID,
                          role: role, text: text, citations: citations,
                          createdAt: Date().timeIntervalSince1970,
                          steps: steps, provider: provider)
        let store = env.store
        let ok = await Task.detached {
            do { try store.appendMessage(msg); return true } catch { return false }
        }.value
        if !ok { saveFailed = true }
    }

    /// Task 7.5 — name a NEW thread properly after its first answer lands: qwen writes a short
    /// topic title from Q+A; keeps the question-derived title on any failure. Only fires when the
    /// title is still the auto-derived one (never clobbers a user rename).
    private func autoTitleIfFirstAnswer(convID: String, question: String, answer: String, _ env: AppEnvironment) {
        let store = env.store
        let scope = meetingID
        let derived = Self.title(from: question)
        Task.detached(priority: .utility) { [weak self] in
            func currentTitle() -> String? {
                if let scope {
                    return ((try? store.conversations(meetingID: scope)) ?? []).first(where: { $0.id == convID })?.title
                }
                return ((try? store.globalConversations()) ?? []).first(where: { $0.id == convID })?.title
            }
            // Authoritative check against the STORE (round-2 MED: a fabricated fallback made the
            // guard always pass when recents was stale — could clobber a user rename).
            let current = currentTitle()
            guard current == derived else { return }
            guard let named = await ChatTitler.title(question: question, answer: answer) else { return }
            // Re-check right before writing (the user may have renamed during the LLM call).
            let still = currentTitle()
            guard still == derived else { return }
            try? store.renameConversation(id: convID, title: named)
            await MainActor.run { [weak self] in
                self?.refreshRecents(env)
            }
        }
    }

    static func title(from q: String) -> String {
        let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count <= 48 ? t : String(t.prefix(46)) + "…"
    }
}

/// Off-main token buffer for the ~30Hz coalesced drain (Task 3.3).
actor TokenAccumulator {
    private var buf = ""
    func append(_ t: String) { buf += t }
    func drain() -> String { let b = buf; buf = ""; return b }
}
