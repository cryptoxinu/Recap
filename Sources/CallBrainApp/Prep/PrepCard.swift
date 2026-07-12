import SwiftUI
import MarkdownUI
import CallBrainCore

/// Calendar v4 — the call-prep card. Shows the FREE continuation context instantly (past
/// calls, open commitments, topics) and a "Generate with AI" action that streams a grounded,
/// cited brief over the prior calls. Reused in the Agenda "Prep for today" hero, in upcoming
/// rows (lazy), and in the calendar event-detail panel.
struct PrepCard: View {
    let event: CalendarEvent
    /// Auto-run the AI brief on appear (the Agenda hero uses this for the NEXT call only).
    var autoGenerate = false

    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var scheme
    @State private var model = PrepModel()
    @State private var research = AttendeeResearchModel()   // "research attendees" for first calls
    // Per-card (audit LOW: a shared @AppStorage flipped every visible card's toggle at once).
    // Seeded from the last-used default so it feels sticky without cross-card coupling.
    @AppStorage("callbrain.prep.webResearchDefault") private var webDefault = false
    @State private var webResearch = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch model.phase {
            case .idle, .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading your past calls…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            default:
                if model.hasContent {
                    controls
                    body(for: model)
                } else {
                    attendeeResearchSection
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.hairline, lineWidth: 1))
        // Keyed on a FINGERPRINT (id + start + title + the actual attendee list) so the card
        // reloads both when the event changes AND when THIS event is edited/dragged — those
        // change the prep source hash while keeping the id. Attendee IDENTITY, not count, or
        // swapping Sam→Alex (same count) would keep the wrong brief (verify-audit HIGH).
        .task(id: "\(event.id)|\(Int(event.start.timeIntervalSince1970))|\(event.title)|\(event.attendees.joined(separator: ","))|\(event.attendeeEmails.joined(separator: ","))") {
            webResearch = webDefault
            await research.prepare(event: event, env: env)   // resolve guests + load any cached briefing
            await model.load(event: event, env: env)
            if autoGenerate, model.hasContent, model.phase == .ready {
                model.startGenerate(event: event, env: env, web: webResearch)
            }
        }
    }

    // MARK: - controls

    private var controls: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(PrepPrompt.Template.allCases) { t in
                    Button(t.label) { Task { await model.setTemplate(t, event: event, env: env) } }
                }
            } label: {
                Label(model.template.label, systemImage: "text.alignleft").font(.system(size: 12))
            }
            .menuStyle(.borderlessButton).fixedSize()
            .disabled(model.phase == .generating)

            Spacer()

            Toggle(isOn: $webResearch) {
                Label("Web", systemImage: "globe").font(.system(size: 11))
            }
            .toggleStyle(.button).controlSize(.small)
            .help("Also research the people/company online")
            .onChange(of: webResearch) { _, on in webDefault = on }   // remember, don't sync live

            if model.phase == .done || model.phase == .refused || model.phase == .failed {
                Button {
                    Task { await model.reset(event: event, env: env)
                           model.startGenerate(event: event, env: env, web: webResearch) }
                } label: { Label("Regenerate", systemImage: "arrow.clockwise").font(.system(size: 12)) }
                    .buttonStyle(.bordered).controlSize(.small)
            } else if model.phase == .ready {
                Button {
                    model.startGenerate(event: event, env: env, web: webResearch)
                } label: { Text("Generate brief").font(.system(size: 12, weight: .semibold)) }
                    .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.small)
            }
        }
    }

    // MARK: - attendee research (first-call empty state)

    /// When there are no prior calls to prep from, offer a one-click web briefing on the EXTERNAL
    /// people/companies on the call — the "who is this and what do they do" the founder actually needs
    /// for a first meeting. Falls back to the plain "first call" note when everyone is a teammate.
    @ViewBuilder private var attendeeResearchSection: some View {
        switch research.phase {
        case .idle, .failed, .unavailable:
            if research.hasTargets {
                VStack(alignment: .leading, spacing: 8) {
                    Text(researchHeadline).font(.system(size: 12)).foregroundStyle(.secondary)
                    Button { research.start(event: event, env: env) } label: {
                        Label("Research attendees", systemImage: "sparkles").font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.small)
                    if (research.phase == .failed || research.phase == .unavailable), let e = research.errorText {
                        Text(e).font(.system(size: 11)).foregroundStyle(Theme.warning)
                    }
                }
            } else {
                Label("First call with these people — nothing to prep from yet.", systemImage: "person.2")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        case .researching:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Researching \(researchSubject) online…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        case .done:
            if let md = research.briefMD {
                HStack(spacing: 8) {
                    Image(systemName: "globe").font(.system(size: 11)).foregroundStyle(Theme.accent)
                    Text("Who's on this call").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Button { research.start(event: event, env: env) } label: {
                        Label("Redo", systemImage: "arrow.clockwise").font(.system(size: 11))
                    }.buttonStyle(.borderless).controlSize(.small)
                }
                MarkdownAnswerView(text: Self.cleanBrief(md))
            }
        }
    }

    /// Human pitch for the research button — names the companies/guests we'll look up.
    private var researchHeadline: String {
        guard let p = research.plan else { return "Research the people on this call." }
        if p.companies.count == 1, let c = p.companies.first {
            return "Look up \(c.name) and who's joining before this first call."
        }
        if p.companies.count > 1 {
            return "Look up the \(p.companies.count) companies joining this first call."
        }
        return "Look up who these external guests are before the call."
    }

    /// Short subject phrase for the in-progress line.
    private var researchSubject: String {
        guard let p = research.plan else { return "the attendees" }
        if let c = p.companies.first, p.companies.count == 1 { return c.name }
        if p.companies.count > 1 { return "\(p.companies.count) companies" }
        return "the attendees"
    }

    // MARK: - body per phase

    @ViewBuilder private func body(for model: PrepModel) -> some View {
        switch model.phase {
        case .generating:
            // A prep brief shows the BRIEF, not the reasoning trace or [S#] markers — the founder trusts
            // it's grounded in the calls; the plumbing is noise here.
            if model.streamingText.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Preparing your brief…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            } else {
                MarkdownAnswerView(text: Self.cleanBrief(model.streamingText))
            }
        case .done, .refused:
            if let brief = model.briefMD {
                MarkdownAnswerView(text: Self.cleanBrief(brief))
            }
            if model.phase == .refused {
                Text("Nothing new to add beyond the summary above.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        case .failed:
            // Fall back to the free context so the card is never empty on an AI error.
            Markdown(Self.cleanBrief(model.deterministicBrief)).markdownTextStyle { FontSize(13) }
            if let e = model.errorText {
                Text(e).font(.system(size: 11)).foregroundStyle(Theme.warning)
            }
        default:   // .ready — free continuation context (no AI yet)
            Markdown(Self.cleanBrief(model.deterministicBrief)).markdownTextStyle { FontSize(13) }
        }
    }

    /// Strip the inline `[S#]` citation markers (and collapsed runs like `[S1][S20]`) from a brief — the
    /// answer stays grounded in the calls, the reader just doesn't see the plumbing.
    static func cleanBrief(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"[ \t]*(\[S\d+\])+"#, with: "", options: .regularExpression)
            // Streaming tail: an unterminated "[S" / "[S1" at the very end before its "]" arrives.
            .replacingOccurrences(of: #"[ \t]*\[S\d*$"#, with: "", options: .regularExpression)
    }
}
