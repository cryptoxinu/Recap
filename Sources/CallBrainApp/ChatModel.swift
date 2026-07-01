import SwiftUI
import CallBrainCore

/// Backs a chat surface and PERSISTS every turn to the Store (Phase 4.5), so the conversation shows up in
/// "Recents" and reopening it restores the full thread + citations. A `meetingID` scopes it to a single
/// call's AskFred (retrieval is hard-filtered to that meeting); nil is the global Ask surface.
@MainActor
@Observable
final class ChatModel {
    var messages: [AskMessage] = []
    var recents: [Conversation] = []
    var busy = false
    var saveFailed = false                  // true if a turn couldn't be persisted (shown in the UI)
    private(set) var conversationID: String?
    let meetingID: String?
    /// The in-flight generation. Owned by the model (not the view), so navigating away doesn't cancel it;
    /// cancelling it (Stop) terminates the underlying CLI subprocess too. `generation` is a monotonic token:
    /// a turn only cleans up `busy`/`task` if it's STILL the current generation, so a stopped-then-resent
    /// turn's late unwind can't clobber the new turn's state (SME H3).
    private var task: Task<Void, Never>?
    private var generation = 0

    init(meetingID: String? = nil) { self.meetingID = meetingID }

    /// Fire-and-forget a question — returns immediately; the answer streams into `messages` in the
    /// background and survives view teardown. Ignored if a generation is already running.
    func send(_ text: String, _ env: AppEnvironment, research: Bool = false) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, task == nil else { return }   // trim FIRST so a whitespace send can't strand `task`
        generation += 1
        let gen = generation
        task = Task { [weak self] in await self?.ask(q, env, research: research, gen: gen) }
    }

    /// Stop the current generation (kills the CLI subprocess via Task cancellation) and finalize the
    /// half-written turn so the UI doesn't sit on a spinner. Bumps `generation` so the cancelled turn's
    /// trailing `defer` is a no-op.
    func stop() {
        task?.cancel(); task = nil; busy = false; generation += 1
        if let i = messages.firstIndex(where: { $0.pending }) {
            messages[i].pending = false
            if messages[i].text.isEmpty || messages[i].text == "Thinking…" { messages[i].text = "_Stopped._" }
            messages[i].status = "stopped"
        }
    }

    /// Monotonic sequence for Recents reloads — a slower earlier read can't clobber a newer one
    /// (last-issued wins, not last-completer; audit MED: overlapping off-main refreshes race).
    @ObservationIgnored private var recentsSeq = 0

    /// Reload the Recents rail. The Store read runs OFF the main thread (Store is thread-safe) so opening
    /// the Ask tab or finishing an answer never blocks the UI; the result is assigned back on the main actor.
    func refreshRecents(_ env: AppEnvironment) {
        let store = env.store, mid = meetingID
        recentsSeq += 1; let seq = recentsSeq
        Task { [weak self] in
            let r = await Task.detached {
                mid == nil ? ((try? store.globalConversations()) ?? [])
                           : ((try? store.conversations(meetingID: mid!)) ?? [])
            }.value
            guard let self, self.recentsSeq == seq else { return }   // a newer refresh superseded this one
            self.recents = r
        }
    }

    /// Abandon the in-flight turn — starting a new chat or switching threads discards the current answer:
    /// cancel the CLI subprocess, clear busy/task, and bump `generation` so any in-flight persist or answer
    /// write bails instead of clobbering the new thread (audit HIGH: ensureConversation reentrancy).
    private func abandonInFlight() {
        task?.cancel(); task = nil; busy = false; generation += 1
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
                AskMessage(role: m.role == .user ? .user : .assistant, text: m.text,
                           citations: m.citations.map {
                               Cite(tag: $0.tag, meetingID: $0.meetingID, chunkID: $0.chunkID,
                                    summary: "\($0.speaker ?? "Unknown") — \($0.text.prefix(80))…")
                           },
                           status: m.role == .assistant ? (m.citations.isEmpty ? "no sources" : "\(m.citations.count) sources") : nil)
            }
        }
    }

    func rename(_ id: String, to title: String, _ env: AppEnvironment) {
        let store = env.store
        Task { [weak self] in
            await Task.detached { try? store.renameConversation(id: id, title: title) }.value
            self?.refreshRecents(env)
        }
    }
    func delete(_ id: String, _ env: AppEnvironment) {
        let store = env.store
        if conversationID == id { newChat() }
        Task { [weak self] in
            await Task.detached { try? store.deleteConversation(id: id) }.value
            self?.refreshRecents(env)
        }
    }

    func ask(_ text: String, _ env: AppEnvironment, research requested: Bool = false, gen explicitGen: Int? = nil) async {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let gen: Int
        if let explicitGen { gen = explicitGen } else { generation += 1; gen = generation }
        busy = true
        defer { if generation == gen { busy = false; task = nil } }   // only if still the current turn (H3)
        // Web research is a global-chat capability (the per-call AskFred stays scoped to that call).
        let useResearch = meetingID == nil && (requested || AskEngine.looksLikeResearch(q))

        // Conversation continuity: feed the prior turns (before this question) back into the engine, so a
        // follow-up ("dig into that", "what about the other call") keeps context across the thread.
        let history: [AskEngine.Turn] = messages.compactMap { m in
            guard !m.pending, !m.text.isEmpty else { return nil }
            return AskEngine.Turn(role: m.role == .user ? .user : .assistant, text: m.text)
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
        if let convID { await persist(.user, text: q, citations: [], conversationID: convID, env) }

        // Live reasoning timeline: append each real pipeline step to the pending message.
        let onStep: AskEngine.StepHandler = { @MainActor [weak self] step in
            guard let self, let i = self.messages.firstIndex(where: { $0.id == pid }) else { return }
            withAnimation(.snappy) { self.messages[i].steps.append(step) }
        }

        do {
            let ans: AskEngine.Answer
            if useResearch {
                ans = try await env.ask.research(q, history: history, onStep: onStep)
            } else if meetingID == nil {
                ans = try await env.ask.ask(q, history: history, onStep: onStep)
            } else {
                ans = try await env.ask.ask(q, inMeeting: meetingID!, history: history, onStep: onStep)
            }
            if Task.isCancelled || generation != gen { return }   // stopped/superseded — discard result (H3)
            let cites = ans.citations.map {
                Cite(tag: $0.tag, meetingID: $0.meetingID, chunkID: $0.chunkID,
                     summary: "\($0.speaker ?? "Unknown") — \($0.text.prefix(80))…")
            }
            if let i = messages.firstIndex(where: { $0.id == pid }) {
                withAnimation(.snappy) {
                    messages[i].text = ans.text
                    messages[i].citations = cites
                    messages[i].pending = false
                    messages[i].status = ans.status == .answered ? "\(cites.count) sources" : "no sources"
                    messages[i].provider = ans.provider
                }
            }
            let stored = ans.citations.map {
                StoredCitation(tag: $0.tag, chunkID: $0.chunkID, meetingID: $0.meetingID,
                               speaker: $0.speaker, text: $0.text)
            }
            if let convID { await persist(.assistant, text: ans.text, citations: stored, conversationID: convID, env) }
            refreshRecents(env)
        } catch {
            if Task.isCancelled || generation != gen { return }   // stopped/superseded — not an error to surface
            if let i = messages.firstIndex(where: { $0.id == pid }) {
                messages[i].text = Self.friendlyFailure(error)
                messages[i].pending = false
                messages[i].status = "failed"      // AskMessageView renders this as an error, not an answer
                messages[i].steps = []             // a failed turn didn't "reason" to an answer — clear the timeline
                messages[i].citations = []         // and it has no sources
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

    /// Retry after a failed turn (convention #4): drop the failed assistant bubble and re-send the last
    /// user question. A no-op if there's nothing to retry or a generation is already running.
    func retryLast(_ env: AppEnvironment) {
        guard task == nil else { return }
        // Find the last user turn; drop everything after it (the failed assistant bubble) and re-send.
        guard let userIdx = messages.lastIndex(where: { $0.role == .user }) else { return }
        let question = messages[userIdx].text
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Remove the failed assistant bubble(s) AND the user turn itself — send() re-appends the user bubble,
        // so this avoids a duplicate "You" row while keeping the earlier conversation history intact.
        messages.removeSubrange(userIdx...)
        send(question, env)
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
                         conversationID: String, _ env: AppEnvironment) async {
        let msg = Message(id: "msg_" + UUID().uuidString, conversationID: conversationID,
                          role: role, text: text, citations: citations,
                          createdAt: Date().timeIntervalSince1970)
        let store = env.store
        let ok = await Task.detached {
            do { try store.appendMessage(msg); return true } catch { return false }
        }.value
        if !ok { saveFailed = true }
    }

    static func title(from q: String) -> String {
        let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count <= 48 ? t : String(t.prefix(46)) + "…"
    }
}
