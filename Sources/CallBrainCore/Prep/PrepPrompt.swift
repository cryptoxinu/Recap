import Foundation

/// Calendar v4 — builds the grounded query that turns a CallPrep.Context into an AI prep
/// brief. The AskEngine system prompt is fixed (answer only over retrieved evidence, cite,
/// refuse if empty); we only craft the QUESTION, so the brief is always grounded in the real
/// transcript chunks of the prior calls — never hallucinated.
public enum PrepPrompt {

    public enum Template: String, Sendable, CaseIterable, Identifiable {
        case brief, talkingPoints, decisionsRecap, openQuestions
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .brief: "Prep brief"
            case .talkingPoints: "Talking points"
            case .decisionsRecap: "Decisions recap"
            case .openQuestions: "Open questions"
            }
        }
    }

    /// The grounded ask. Names the upcoming call and its people so retrieval + synthesis stay
    /// on-topic; the instruction body varies by template. Kept as prose (not JSON) — the
    /// answer renders as the brief markdown directly.
    public static func query(context: CallPrep.Context, template: Template = .brief) -> String {
        let df = DateFormatter()
        df.dateFormat = "EEEE MMM d 'at' h:mm a"
        df.locale = Locale(identifier: "en_US_POSIX")
        let whenStr = df.string(from: context.start)
        let people = context.attendees.isEmpty ? "the attendees"
            : context.attendees.prefix(8).joined(separator: ", ")

        let head = "I have an upcoming call \u{201C}\(context.eventTitle)\u{201D} on \(whenStr) "
            + "with \(people). Using ONLY our past calls with these people on this topic, "

        let body: String
        switch template {
        case .brief:
            body = "prepare me for it. START with a one-line **Bottom line** \u{2014} the single most "
                + "important thing to walk in knowing. THEN cover, in short scannable bullets (bold the "
                + "key term; cite the call): where we left off, open commitments and who owns them, "
                + "decisions already made (so I don\u{2019}t relitigate), what I should follow up on, and "
                + "3\u{2013}5 sharp talking points. Be specific and TIGHT \u{2014} no filler, no restating "
                + "the obvious, short sections not an essay."
        case .talkingPoints:
            body = "give me 5\u{2013}8 concrete talking points I should raise, each grounded in "
                + "something specific from a past call (cite it). One line each."
        case .decisionsRecap:
            body = "recap the decisions we've already made and any that are still open, so I "
                + "don't relitigate settled points. Cite each decision."
        case .openQuestions:
            body = "list the open questions and unresolved threads I should get answered on "
                + "this call, each tied to where it came up (cite it)."
        }
        return head + body
    }

    /// A compact, ALWAYS-shown fallback assembled with zero LLM cost from the free context —
    /// used in local-only mode and as the instant preview before the user hits Generate.
    public static func deterministicBrief(_ context: CallPrep.Context) -> String {
        guard context.hasContent else {
            return "This looks like your first call with these people \u{2014} nothing to prep from yet."
        }
        var out = ""
        // "Where you left off" is a RECENCY claim — use the most RECENT prior call, not the
        // highest-ranked (audit LOW: an older attendee-matched call could outrank a newer one).
        if let last = context.priorMeetings.max(by: { $0.date < $1.date }) {
            out += "**Where you left off** \u{2014} \(last.title) (\(last.date))"
            if let one = last.oneLiner, !one.isEmpty { out += "\n\(one)" }
            out += "\n\n"
        }
        if !context.openCommitments.isEmpty {
            out += "**Open commitments**\n"
            for c in context.openCommitments.prefix(8) {
                let who = c.owner.map { "\($0): " } ?? ""
                out += "- \(who)\(c.text)\n"
            }
            out += "\n"
        }
        if !context.recurringTopics.isEmpty {
            out += "**Recurring topics** \u{2014} " + context.recurringTopics.joined(separator: ", ") + "\n\n"
        }
        if context.priorMeetings.count > 1 {
            out += "**Past calls**\n"
            for m in context.priorMeetings {
                out += "- \(m.title) \u{2014} \(m.date)\n"
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stable hash of EVERY input that determines a brief — the cache invalidates on a
    /// reschedule, attendee change, or any change to the contributing calls' titles / dates /
    /// summaries / tasks (audit HIGH: a text-only hash let a stale brief survive those).
    /// Deterministic FNV-1a (NOT Swift's `Hasher`, which reseeds every process → a persisted
    /// key must survive relaunch). Fields are length-delimited so no boundary is ambiguous.
    public static func sourceHash(_ context: CallPrep.Context) -> String {
        func field(_ s: String) -> String { "\(s.utf8.count):\(s)\u{1}" }
        var acc = field(context.eventTitle)
        acc += field(String(Int(context.start.timeIntervalSince1970)))
        acc += field(context.attendees.joined(separator: "\u{2}"))
        for m in context.priorMeetings {
            acc += field(m.meetingID) + field(m.title) + field(m.date)
                + field(m.summary ?? "") + field(m.openTasks.joined(separator: "\u{2}"))
        }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in acc.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
