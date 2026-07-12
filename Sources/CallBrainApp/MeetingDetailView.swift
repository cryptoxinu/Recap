import SwiftUI
import AppKit
import CallBrainCore

struct MeetingDetailView: View {
    @Environment(AppEnvironment.self) private var env
    let meetingID: String
    /// "Explain This" appears ONLY where a consumer exists (the workspace's docked AskFred) —
    /// standalone sheets (citations, Tasks, Import) would strand the request (phase-4 gate MED).
    var explainEnabled: Bool = false
    /// A cited chunk to scroll to + flash. Dynamic: when the parent (the workspace) changes it on a
    /// citation tap, the transcript scrolls to the matching turn (timestamp-linked navigation).
    var highlightChunkID: String? = nil

    @State private var meeting: Store.MeetingRow?
    @State private var followUpDraft: FollowUpBox?   // Calendar v4 — schedule-follow-up sheet
    @State private var groups: [TurnGroup] = []
    @State private var noteLines: [String] = []      // populated for Gemini-notes meetings
    @State private var people: [Entity] = []         // native-NER people mentioned
    @State private var highlightGroupID: Int?
    @State private var citedNoteSnippet = ""          // Gemini-notes accent snippet — resolved OFF-MAIN, cached
    @State private var highlightSeq = 0               // drops out-of-order highlight resolves
    @State private var reloadMetaSeq = 0              // drops out-of-order meta reloads
    @State private var tasks: [ActionItem] = []      // action items for this call (Summary tab)
    @State private var tab: Tab = .summary
    @State private var didAutoSummarize = false
    @State private var renaming = false
    @State private var renameText = ""
    // Task 9.5 — transcript repair: rename a speaker across THIS call (FTS-safe backfill).
    @State private var renameSpeakerFrom: String?
    @State private var exportError: String?   // gate LOW: surfaced export failures
    @State private var linkedEvent: Store.EventLink?   // C3: the call's calendar event
    @State private var renameSpeakerTo = ""
    // #42 — click-to-correct: tap a word in a line, say what it should be → grows the vocabulary.
    @State private var correctingLine: String?
    @State private var fixWrong = ""
    @State private var fixRight = ""
    // #42 — "Train with AI": mine likely mis-transcriptions → human approves → dictionary grows.
    @State private var mining = false
    @State private var minedProposals: [AskEngine.MinedCorrection]?
    @State private var correctionStatus: String?   // "Learned N terms…" / "No new corrections" confirmation

    // Find-in-transcript
    @State private var findActive = false
    @State private var findText = ""
    @State private var matchIndex = 0

    enum Tab: String, CaseIterable { case summary = "Summary", gemini = "Gemini", transcript = "Transcript" }

    private var isNotes: Bool { meeting?.source == "gmeet_gemini" }
    private var hasNotes: Bool { !noteLines.isEmpty }         // Gemini notes present (incl. merged-in)
    private var hasTranscript: Bool { !groups.isEmpty }       // real speaker-attributed dialogue present
    /// Tabs adapt to the call. A pure Gemini-notes call = Summary + Gemini (no verbatim transcript). A
    /// recording/Fathom/Fireflies call = Summary + Transcript. A MERGED recording+notes call shows BOTH
    /// (Summary + Gemini + Transcript) — Google's notes and the real "who said what" transcript never share
    /// a tab, and the notes never masquerade as speaker turns.
    private var availableTabs: [Tab] {
        var t: [Tab] = [.summary]
        if hasNotes { t.append(.gemini) }
        if hasTranscript { t.append(.transcript) }
        return t
    }
    /// The non-summary content tab to jump to (the verbatim transcript when there is one, else the notes).
    private var contentTab: Tab { hasTranscript ? .transcript : .gemini }
    private var showsTabs: Bool { availableTabs.count > 1 }
    private var hasSummary: Bool { !(meeting?.callSummary?.isEmpty ?? true) }

    struct TurnGroup: Identifiable, Sendable {
        let id: Int
        let speaker: String
        let tStart: Double?
        let isInferred: Bool
        var lines: [String]
        var joined: String { lines.joined(separator: " ") }
    }

    /// Everything the detail view loads for a call — built OFF the main thread so opening a large call
    /// never freezes navigation.
    struct LoadSnapshot: Sendable {
        var meeting: Store.MeetingRow?
        var tasks: [ActionItem] = []
        var people: [Entity] = []
        var noteLines: [String] = []
        var groups: [TurnGroup] = []
    }

    /// Group ids matching the find query (transcript), in order — CACHED so it's computed once per query
    /// change, not re-filtered for every row (that was O(n²) on long transcripts).
    @State private var matchIDs: [Int] = []
    @State private var matchSet: Set<Int> = []
    private var matches: [Int] { matchIDs }
    private func recomputeMatches() {
        let q = findText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { matchIDs = []; matchSet = []; return }
        matchIDs = groups.filter { $0.joined.lowercased().contains(q) || $0.speaker.lowercased().contains(q) }.map(\.id)
        matchSet = Set(matchIDs)
    }
    /// Note lines matching the find query (Gemini notes render as one collapsed group, so the transcript
    /// `matches` count would always be 1 — count actual lines instead; gate LOW).
    private var noteMatchCount: Int {
        let q = findText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return 0 }
        return noteLines.filter { $0.lowercased().contains(q) }.count
    }
    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if findActive { findBar(proxy).transition(.move(edge: .top).combined(with: .opacity)) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        tabPicker
                        Divider()
                        tabContent.animation(Theme.springy, value: tab)
                    }
                    .padding(28)
                    .frame(maxWidth: 860, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .task {
                await load()
                let store = env.store, mid = meetingID
                linkedEvent = await Task.detached { try? store.eventLink(meetingID: mid) }.value
                env.suggestSpeakerNames(for: meetingID)   // Task 8.1: propose names for Speaker N
                await autoSummarizeIfNeeded()
                // Screenshot QA: CALLBRAIN_FIND=<query> opens the Find bar pre-filled.
                if let f = ProcessInfo.processInfo.environment["CALLBRAIN_FIND"], !f.isEmpty {
                    findActive = true; findText = f
                    if showsTabs { tab = contentTab }            // mount the content tab (Gemini/Transcript)
                    recomputeMatches()
                    if let first = matchIDs.first { scrollTo(first, proxy) }
                }
                await scrollToHighlight(proxy)
            }
            .onChange(of: highlightChunkID) { _, _ in
                Task { await resolveHighlight(); await scrollToHighlight(proxy) }
            }
            .onChange(of: env.titlesRevision) { _, _ in
                Task {
                    await reloadMeta()
                    let store = env.store, mid = meetingID
                    linkedEvent = await Task.detached { try? store.eventLink(meetingID: mid) }.value
                }
            }
            .onChange(of: env.findRequest) {   // ⌘F menu command (gate MED, Task 7.2)
                findActive = true
                if showsTabs { tab = contentTab }
            }
        }
        .safeAreaInset(edge: .top) {   // Task 8.1 — confirm-only speaker naming banner
            if let proposals = env.speakerProposals[meetingID], !proposals.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "person.wave.2").foregroundStyle(Theme.accent)
                    Text(proposals.map { "\($0.speaker) is \($0.name)" }.joined(separator: " · "))
                        .font(.callout).lineLimit(1)
                    Text("Apply these names?").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Apply") { Task { await env.applySpeakerNames(for: meetingID); await load() } }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    Button("Dismiss") { env.dismissSpeakerProposal(for: meetingID) }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.bar)
                .overlay(alignment: .bottom) { Divider() }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .navigationTitle(meeting?.displayTitle ?? "Meeting")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    withAnimation(.snappy) { findActive.toggle(); if findActive, showsTabs { tab = contentTab } }
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .help(isNotes ? "Find in notes" : "Find in transcript")
            }
            ToolbarItem(placement: .automatic) {   // Calendar v4 — schedule a follow-up
                Button { followUpDraft = makeFollowUpDraft() } label: {
                    Image(systemName: "calendar.badge.plus")
                }
                .help("Schedule a follow-up meeting")
            }
            ToolbarItem(placement: .automatic) {   // Task 8.5 — export/share
                Menu {
                    Button { copyRecap() } label: { Label("Copy Recap", systemImage: "doc.on.doc") }
                    Button { exportMarkdown() } label: { Label("Export Markdown…", systemImage: "square.and.arrow.down") }
                    Button { exportPDF() } label: { Label("Export PDF…", systemImage: "doc.richtext") }
                } label: { Image(systemName: "square.and.arrow.up") }
                .help("Share this call")
            }
        }
        .sheet(item: $followUpDraft) { box in
            EventEditorView(existing: nil, initialDraft: box.draft) {}
        }
        .sheet(isPresented: $renaming) { renameSheet }
        .alert("Couldn't export", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: { Text(exportError ?? "") }
        .alert("Rename speaker", isPresented: Binding(get: { renameSpeakerFrom != nil },
                                                      set: { if !$0 { renameSpeakerFrom = nil } })) {
            TextField("Real name", text: $renameSpeakerTo)
            Button("Rename") {
                guard let from = renameSpeakerFrom else { return }
                let to = renameSpeakerTo.trimmingCharacters(in: .whitespacesAndNewlines)
                renameSpeakerFrom = nil
                guard !to.isEmpty, to != from else { return }
                let store = env.store, mid = meetingID
                Task { @MainActor in
                    _ = await Task.detached { try? store.renameSpeaker(meetingID: mid, from: from, to: to) }.value
                    await load()   // refresh the transcript with the new name
                }
            }
            Button("Cancel", role: .cancel) { renameSpeakerFrom = nil }
        } message: {
            Text("Every “\(renameSpeakerFrom ?? "")” line in this call becomes the new name — transcript, search, and future answers.")
        }
        .sheet(isPresented: Binding(get: { correctingLine != nil }, set: { if !$0 { correctingLine = nil } })) {
            FixWordSheet(context: correctingLine ?? "", wrong: $fixWrong, right: $fixRight,
                onSave: {
                    let w = fixWrong.trimmingCharacters(in: .whitespacesAndNewlines)
                    let r = fixRight.trimmingCharacters(in: .whitespacesAndNewlines)
                    correctingLine = nil
                    // Names/jargon only — a common word / homophone would corrupt unrelated calls (audit MED).
                    guard !w.isEmpty, !r.isEmpty, w.lowercased() != r.lowercased(),
                          !CorrectionDictionary.isRiskyWrong(w) else { return }
                    // Adds the correction AND retroactively fixes every OLD call that contains it (TC5).
                    env.addCorrection(CorrectionEntry(wrong: w, right: r, origin: .manual))
                    Task { await load() }   // re-apply to THIS call now (the "it tunes" feedback)
                },
                cancel: { correctingLine = nil })
        }
        .sheet(isPresented: Binding(get: { minedProposals != nil }, set: { if !$0 { minedProposals = nil } })) {
            TrainWithAIReviewView(proposals: minedProposals ?? [],
                onApprove: { approved in
                    let shown = minedProposals ?? []
                    minedProposals = nil
                    // Remember the ones you SAW but didn't approve, so re-running never re-surfaces them.
                    let approvedKeys = Set(approved.map { CorrectionDictionary.RejectedProposals.rejectionKey(heard: $0.heard, shouldBe: $0.shouldBe) })
                    CorrectionDictionary.RejectedProposals.remember(
                        shown.map { CorrectionDictionary.RejectedProposals.rejectionKey(heard: $0.heard, shouldBe: $0.shouldBe) }
                             .filter { !approvedKeys.contains($0) })
                    guard !approved.isEmpty else { return }
                    // Add the approved terms AND retroactively fix every OLD call containing them (TC5).
                    env.addCorrections(approved.map { CorrectionEntry(wrong: $0.heard, right: $0.shouldBe, origin: .mined) })
                    withAnimation(Theme.smooth) {
                        correctionStatus = "Learned \(approved.count) new term\(approved.count == 1 ? "" : "s") — your library now knows \(env.corrections.entries.count), and every past call is being updated."
                    }
                    Task { await load() }   // re-apply the newly-learned terms to THIS call now
                },
                cancel: { minedProposals = nil })
        }
    }

    private func beginRename() { renameText = meeting?.displayTitle ?? ""; renaming = true }

    // MARK: - export/share (Task 8.5)

    /// The call as clean markdown: title, date, one-liner, summary, open tasks.
    private func recapMarkdown() -> String {
        var out = "# \(meeting?.displayTitle ?? "Call")\n"
        if let d = meeting?.date { out += "_\(d)_\n\n" }
        if let one = meeting?.aiSummary, !one.isEmpty { out += "\(one)\n\n" }
        if let sum = meeting?.callSummary, !sum.isEmpty { out += "\(sum)\n\n" }
        let tasks = (try? env.store.tasks(meetingID: meetingID)) ?? []
        let open = tasks.filter { $0.status != .done }
        if !open.isEmpty {
            out += "## Action items\n"
            for t in open { out += "- [ ] \(t.owner.map { "**\($0)**: " } ?? "")\(t.text)\n" }
        }
        return out
    }

    private func copyRecap() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(recapMarkdown(), forType: .string)
    }

    private func exportMarkdown() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(meeting?.displayTitle ?? "call").md"
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try recapMarkdown().data(using: .utf8)?.write(to: url) }
        catch { exportError = error.localizedDescription }   // gate LOW: never swallow a failed save
    }

    private func exportPDF() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(meeting?.displayTitle ?? "call").pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Render the recap markdown into an attributed text view → paginated PDF.
        let md = recapMarkdown()
        let attr = (try? NSAttributedString(markdown: md,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? NSAttributedString(string: md)
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 612 - 96, height: 10))
        tv.textStorage?.setAttributedString(attr)
        tv.sizeToFit()
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 612, height: 792)   // US Letter
        info.topMargin = 48; info.bottomMargin = 48; info.leftMargin = 48; info.rightMargin = 48
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let op = NSPrintOperation(view: tv, printInfo: info)
        op.showsPrintPanel = false; op.showsProgressPanel = false
        if !op.run() { exportError = "The PDF couldn't be written. Try again." }   // r2 MED
    }

    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename call").font(.headline)
            TextField("Title", text: $renameText).textFieldStyle(.roundedBorder).frame(width: 380)
                .onSubmit { commitRename() }
            if let orig = meeting?.title {
                Text("The original title (“\(orig)”) is kept — this is just what shows in your lists.")
                    .font(.caption).foregroundStyle(.secondary).frame(width: 380, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Cancel") { renaming = false }
                Button("Save") { commitRename() }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    private func commitRename() {
        let t = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }   // Enter on a blank field must NOT clear the title (matches disabled Save)
        renaming = false
        Task { await env.renameMeeting(meetingID, to: t); await reloadMeta() }
    }

    private func findBar(_ proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(isNotes ? "Find in notes…" : "Find in transcript…", text: $findText)
                .textFieldStyle(.plain)
                .onSubmit { jump(+1, proxy) }
                .onChange(of: findText) { _, _ in
                    matchIndex = 0; recomputeMatches()
                    if !isNotes, let f = matchIDs.first { scrollTo(f, proxy) }
                }
            if isNotes {
                // Notes have no scroll anchors → highlight-only, but report the real matching-line count.
                if noteMatchCount > 0 {
                    Text("\(noteMatchCount) match\(noteMatchCount == 1 ? "" : "es")")
                        .font(.caption).foregroundStyle(.secondary)
                } else if !findText.isEmpty {
                    Text("No matches").font(.caption).foregroundStyle(.secondary)
                }
            } else if !matches.isEmpty {
                Text("\(min(matchIndex + 1, matches.count)) / \(matches.count)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button { jump(-1, proxy) } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain)
                Button { jump(+1, proxy) } label: { Image(systemName: "chevron.down") }.buttonStyle(.plain)
            } else if !findText.isEmpty {
                Text("No matches").font(.caption).foregroundStyle(.secondary)
            }
            Button { withAnimation(.snappy) { findActive = false; findText = "" } } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Theme.cardFill)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func jump(_ dir: Int, _ proxy: ScrollViewProxy) {
        guard !matches.isEmpty else { return }
        matchIndex = ((matchIndex + dir) % matches.count + matches.count) % matches.count
        scrollTo(matches[matchIndex], proxy)
    }

    private func scrollTo(_ id: Int, _ proxy: ScrollViewProxy) {
        withAnimation(.easeInOut) { proxy.scrollTo(id, anchor: .center) }
    }

    /// True when the AI gave the call a meaningful name that differs from its raw (often date-stamp) title.
    private var renamed: Bool {
        guard let m = meeting else { return false }
        return (m.aiTitle?.isEmpty == false) && m.aiTitle != m.title
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text(meeting?.displayTitle ?? "Meeting").font(.cbLargeTitle).foregroundStyle(Theme.textPrimary)
                Button { beginRename() } label: { Image(systemName: "pencil").font(.body) }
                    .buttonStyle(.plain).foregroundStyle(Theme.textTertiary).help("Rename this call")
            }
            .contextMenu { Button { beginRename() } label: { Label("Rename…", systemImage: "pencil") } }
            if let s = meeting?.aiSummary, !s.isEmpty {
                Text(s).font(.system(size: 15)).foregroundStyle(Theme.textSecondary)
            }
            if let m = meeting {
                // FlowLayout (not a fixed HStack) so the up-to-5 meta labels wrap to a second line on a
                // narrowed detail window instead of clipping/truncating off-screen.
                FlowLayout(spacing: 14) {
                    Label(m.date, systemImage: "calendar")
                    if let ev = linkedEvent {
                        // C3: the auto-linked calendar event — the call's real-world anchor.
                        Label("\(ev.eventTitle) · \(ev.eventStart.formatted(date: .omitted, time: .shortened))",
                              systemImage: "calendar.badge.checkmark")
                            .foregroundStyle(Theme.accent)
                            .lineLimit(1)
                            .help("Linked calendar event (matched by time, title, and attendees)")
                    }
                    Label(sourceLabel(m.source), systemImage: "doc.text")
                    if renamed { Label(m.title, systemImage: "tag").lineLimit(1) }   // original title
                    if isNotes {
                        Label("AI meeting notes", systemImage: CBIcon.aiNotes)
                    } else {
                        Label("\(groups.count) turns", systemImage: "bubble.left.and.bubble.right")
                    }
                    if let cat = m.category, !cat.isEmpty, cat != kOtherVentureID {
                        CategoryTag(id: cat, ventures: env.ventures)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            if !people.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(people) { Chip(text: $0.name, icon: "person.fill") }
                }
                .padding(.top, 2)
                .animation(Theme.springy, value: people.map(\.name))
                .transition(.opacity)
            }
        }
    }

    private var tabPicker: some View {
        Picker("View", selection: $tab) {
            ForEach(availableTabs, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .tint(Theme.accent)
        .frame(maxWidth: 280, alignment: .leading)
    }

    /// Summary | Transcript panes — each fades as the tab switches (no hard cut).
    @ViewBuilder private var tabContent: some View {
        switch tab {
        case .summary:
            summaryTab.transition(.opacity)
        case .gemini:
            // Google's OWN notes (what Gemini generated) — its own tab, separate from our AI Summary.
            GeminiNotesView(lines: noteLines, title: meeting?.title,
                            highlight: findText, citedSnippet: citedNoteSnippet,
                            meetingID: explainEnabled ? meetingID : nil)
                .transition(.opacity)
        case .transcript:
            VStack(alignment: .leading, spacing: 14) {
                if let s = correctionStatus { correctionBanner(s) }
                if !groups.isEmpty { trainWithAIBar }
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(groups) { turn($0).id($0.id) }
                }
            }
            .animation(Theme.springy, value: groups.count)
            .transition(.opacity)
        }
    }

    /// "Train with AI" (#42): proofread THIS call for mis-transcribed crypto/company terms and propose
    /// corrections you approve — which then fix every future call. Unobtrusive; the whole loop is opt-in.
    private var trainWithAIBar: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "checkmark.seal").font(.cbCaption).foregroundStyle(Theme.accent)
            Text("Wrong words? Fix them by right-clicking a line, or let AI find them.")
                .font(.cbCaption).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: Space.s)
            Button {
                Task { await trainWithAI() }
            } label: {
                HStack(spacing: 5) {
                    if mining { ProgressView().controlSize(.small) }
                    Text(mining ? "Scanning…" : "Train with AI").font(.cbCaption.weight(.medium))
                }
            }
            .buttonStyle(.bordered).controlSize(.small).disabled(mining)
        }
        .padding(.horizontal, Space.m).padding(.vertical, Space.s)
        .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Theme.accentSoft))
        .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).strokeBorder(Theme.accent.opacity(0.12)))
    }

    /// A brief success confirmation after Train-with-AI (auto-dismisses) — makes the feature's effect
    /// visible ("Learned N terms…" / "No new corrections…") instead of leaving the founder guessing.
    private func correctionBanner(_ s: String) -> some View {
        Label(s, systemImage: "checkmark.seal.fill")
            .font(.cbCaption).foregroundStyle(Theme.success)
            .padding(.horizontal, Space.m).padding(.vertical, Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Theme.successSoft))
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: s) { try? await Task.sleep(for: .seconds(6)); withAnimation(Theme.smooth) { correctionStatus = nil } }
    }

    private func trainWithAI() async {
        guard !mining else { return }
        mining = true
        defer { mining = false }
        let store = env.store, id = meetingID
        // Mine the RAW stored transcript (NOT the display-corrected text) so the model sees the ACTUAL
        // errors — anti-amplification: already-applied corrections must never feed back as ground truth.
        // Fall back to raw transcript CHUNKS when there are no utterances (legacy/chunk-only calls), so
        // mining doesn't falsely report "clean" on a call that clearly has text (audit MED).
        let raw = await Task.detached { () -> String in
            let utts = (try? store.utterances(meetingID: id)) ?? []
            let lines: [String] = utts.isEmpty
                ? ((try? store.transcript(meetingID: id)) ?? []).map { ($0.speaker.map { "\($0): " } ?? "") + $0.text }
                : utts.map { ($0.speaker.map { "\($0): " } ?? "") + $0.text }
            return lines.joined(separator: "\n")
        }.value
        let glossary = env.corrections.watchlist
        let proposals = await env.ask.mineCorrections(transcript: raw, glossary: glossary)
        // Drop ones already in the dictionary, RISKY ones (common words/homophones), AND ones you already
        // REJECTED — so the review only shows safe, genuinely-NEW learnings and re-running converges instead
        // of re-surfacing the same batch (the miner is a stochastic LLM). (audit MED + founder: idempotency.)
        let known = Set(env.corrections.entries.map(\.id))
        let rejected = CorrectionDictionary.RejectedProposals.load()
        let fresh = proposals.filter {
            !known.contains($0.heard.lowercased())
                && !CorrectionDictionary.isRiskyWrong($0.heard)
                && !rejected.contains(CorrectionDictionary.RejectedProposals.rejectionKey(heard: $0.heard, shouldBe: $0.shouldBe))
        }
        // Nothing new → tell the founder plainly (answers "does it know it already did it?") instead of
        // opening an empty review sheet.
        if fresh.isEmpty {
            withAnimation(Theme.smooth) {
                correctionStatus = "No new corrections — this call already matches your learned vocabulary (\(env.corrections.entries.count) terms)."
            }
            minedProposals = nil
        } else {
            minedProposals = fresh
        }
    }

    // MARK: - Summary tab

    private var isSummarizing: Bool { env.summaries.isWorking(on: meetingID) }
    private var isQueued: Bool { env.summaries.isQueued(meetingID) }
    private var autoPaused: Bool { env.summaries.autoPausedForPower }

    @ViewBuilder private var summaryTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            actionItemsSection
            summaryBody
        }
    }

    @ViewBuilder private var actionItemsSection: some View {
        if !tasks.isEmpty {
            VStack(alignment: .leading, spacing: Space.s) {
                Label("Action items", systemImage: "checklist").font(.cbHeadline).foregroundStyle(Theme.textPrimary)
                ForEach(tasks) { actionRow($0) }
            }
            .animation(Theme.springy, value: tasks)
        }
    }

    private func actionRow(_ item: ActionItem) -> some View {
        Button { toggleTask(item) } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: item.status == .done ? "checkmark.circle.fill" : "circle")
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(item.status == .done ? Theme.accent : Color.secondary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.text)
                        .strikethrough(item.status == .done)
                        .foregroundStyle(item.status == .done ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let o = item.owner, !o.isEmpty {
                        Text(o).font(.caption).foregroundStyle(Theme.accent)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var summaryBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Summary", systemImage: "doc.text").font(.cbHeadline).foregroundStyle(Theme.textPrimary)
                Spacer()
                summaryStatusLabel
            }
            Group {
                if let s = meeting?.callSummary, !s.isEmpty {
                    MarkdownAnswerView(text: s).transition(.opacity)
                } else if isSummarizing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Summarizing locally…").foregroundStyle(.secondary)
                    }
                    .transition(.opacity)
                } else if env.summaries.summaryFailed(meetingID) {
                    // The last attempt failed (local model down AND no CLI subscription) — say so honestly
                    // instead of reverting to the neutral "No summary yet" as if the user never tried.
                    Label("Couldn't generate a summary — the on-device model (Ollama) isn't running and no AI "
                          + "subscription is available. Start Ollama or set up Claude/Codex in Settings, then try again.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                } else {
                    Text(autoPaused
                         ? "Summary paused to save battery — generate it now below."
                         : (isNotes ? "Summarizing Google's notes… (full notes are on the Transcript tab)"
                                    : "No summary yet — generate one below."))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            .animation(Theme.smooth, value: meeting?.callSummary)
            .animation(Theme.smooth, value: isSummarizing)
            .animation(Theme.smooth, value: env.summaries.summaryFailed(meetingID))
            regenerateBar
        }
    }

    @ViewBuilder private var summaryStatusLabel: some View {
        if isNotes && !hasSummary {
            Label("Google's notes", systemImage: CBIcon.aiNotes).font(.cbCaption).foregroundStyle(Theme.textSecondary)
        } else if meeting?.summarySource == "cloud" {
            Label("AI · premium", systemImage: CBIcon.premium).font(.cbCaption).foregroundStyle(Theme.textSecondary)
        } else if hasSummary {
            Label("On-device model", systemImage: "cpu").font(.cbCaption).foregroundStyle(Theme.textSecondary)
        }
    }

    @ViewBuilder private var regenerateBar: some View {
        HStack(spacing: 12) {
            if isSummarizing || isQueued {
                ProgressView().controlSize(.small)
                Text(isSummarizing ? "Summarizing…" : "Queued…").font(.caption).foregroundStyle(.secondary)
            } else {
                Button { generate(cloud: false) } label: {
                    Label(hasSummary ? "Regenerate" : "Generate summary", systemImage: "arrow.clockwise")
                }
                Button { generate(cloud: true) } label: { Label("Regenerate with premium AI", systemImage: CBIcon.premium) }
                    .help("Use your Claude / Codex subscription for a premium-quality pass")
            }
        }
        .font(.callout)
        .padding(.top, 2)
    }

    private func generate(cloud: Bool) { env.summaries.requestNow(meetingID, cloud: cloud) }

    private func toggleTask(_ item: ActionItem) {
        let next: ActionItem.Status = item.status == .done ? .open : .done
        let store = env.store
        // The DB write runs off-main; only reflect the toggle in the UI if the row actually changed,
        // otherwise reload so the checklist never lies about a task that was deleted/reconciled away.
        Task {
            let changed = await Task.detached(operation: { (try? store.setTaskStatus(id: item.id, next)) == true }).value
            if changed {
                withAnimation(Theme.springy) {
                    if let i = tasks.firstIndex(where: { $0.id == item.id }) { tasks[i].status = next }
                }
                env.refreshReminders()
            } else {
                await reloadMeta()
            }
        }
    }

    /// Auto-generate a local summary the first time a non-Gemini call is opened without one (the import
    /// pass usually beat us here; this covers calls imported before the feature). Battery-gated by the
    /// scheduler. Gemini calls reuse Google's notes — no generation.
    private func autoSummarizeIfNeeded() async {
        guard !didAutoSummarize, !hasSummary else { return }   // every call gets a digest, Gemini included
        didAutoSummarize = true
        env.summaries.enqueueAuto(meetingID)
    }

    /// Refresh just the meeting row + tasks (after a summary/regenerate lands) without rebuilding the
    /// transcript groups.
    private func reloadMeta() async {
        reloadMetaSeq += 1; let seq = reloadMetaSeq
        let store = env.store, id = meetingID
        let (m, t) = await Task.detached(operation: {
            ((try? store.meeting(id: id)), (try? store.tasks(meetingID: id)) ?? [])
        }).value
        guard reloadMetaSeq == seq else { return }        // a newer reload superseded this one
        withAnimation(Theme.springy) {   // title/category/summary settle in, not pop
            if let m { meeting = m }
            tasks = t
        }
    }

    private func turn(_ g: TurnGroup) -> some View {
        let isMatch = !findText.isEmpty && matchSet.contains(g.id)
        let isCurrentMatch = isMatch && matches.indices.contains(matchIndex) && matches[matchIndex] == g.id
        return HStack(alignment: .top, spacing: 12) {
            avatar(g.speaker)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(g.speaker).font(.subheadline).bold().foregroundStyle(color(for: g.speaker))
                    if let t = g.tStart, t > 0 {
                        Text(timestamp(t)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if g.isInferred {
                        Text("inferred").font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.secondary.opacity(0.15), in: Capsule()).foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(g.lines.enumerated()), id: \.offset) { _, line in
                    Text(line).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(2).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.s)
        .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(turnFill(g.id, isMatch: isMatch, isCurrent: isCurrentMatch)))
        .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            .strokeBorder(isCurrentMatch ? Theme.warning.opacity(0.7) : .clear, lineWidth: 1.5))
        // Right-click → copy this line (in addition to drag-select), so a quote is one action to grab.
        .contextMenu {
            if explainEnabled {
                Button {
                    // Task 4.5 (founder: "what the heck did that mean?") → docked AskFred explains
                    // this line in plain language, grounded in this call.
                    env.explainRequest = .init(text: g.joined, meetingID: meetingID)
                } label: { Label("Explain This", systemImage: "questionmark.bubble") }
                Divider()
            }
            Button {
                Self.copyToPasteboard("\(g.speaker): \(g.joined)")
            } label: { Label("Copy line", systemImage: "doc.on.doc") }
            Button {
                renameSpeakerFrom = g.speaker; renameSpeakerTo = ""
            } label: { Label("Rename “\(g.speaker)” in this call…", systemImage: "person.crop.circle.badge.questionmark") }
            Button {
                fixWrong = ""; fixRight = ""; correctingLine = g.joined
            } label: { Label("Fix a mis-transcribed word…", systemImage: "character.cursor.ibeam") }
            Button {
                Self.copyToPasteboard(g.joined)
            } label: { Label("Copy text only", systemImage: "text.quote") }
        }
    }

    static func copyToPasteboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func turnFill(_ id: Int, isMatch: Bool, isCurrent: Bool) -> Color {
        if id == highlightGroupID { return Theme.accentSoft }
        if isCurrent { return Theme.warningSoft }
        if isMatch { return Theme.warning.opacity(0.08) }
        return .clear
    }

    private func avatar(_ name: String) -> some View {
        let initials = name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined()
        let hue = color(for: name)
        // Hue wash for identity + a hue RING; initials are neutral primary ink so contrast always clears
        // AA (same-hue-on-same-hue failed for teal/rose — P3 audit MED). The name still carries the hue.
        return Text(initials.isEmpty ? "•" : initials.uppercased())
            .font(.caption.bold()).foregroundStyle(Theme.textPrimary)
            .frame(width: 30, height: 30)
            .background(hue.opacity(0.16), in: Circle())
            .overlay(Circle().strokeBorder(hue.opacity(0.45), lineWidth: 1))
    }

    /// Deterministic per-speaker hue from the curated, dark-tuned palette (was a raw 8-color system rainbow).
    /// Legible as name text on `surface` in both modes.
    private func color(for name: String) -> Color { Theme.speakerColor(name) }

    private func sourceLabel(_ s: String) -> String {
        switch s {
        case "gmeet_gemini": "Google Meet (Gemini notes)"
        case "gmeet_captions": "Google Meet captions"
        case "gmeet_local", "gmeet_cloud": "Google Meet"
        case "fireflies": "Fireflies"
        case "fathom": "Fathom"
        case "cluely": "Cluely"
        case "paste": "Pasted / AI-resolved"
        default: s
        }
    }

    private func timestamp(_ s: Double) -> String {
        let total = Int(s)
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    private func scrollToHighlight(_ proxy: ScrollViewProxy) async {
        guard let h = highlightGroupID else { return }
        try? await Task.sleep(for: .milliseconds(120))
        withAnimation(.easeInOut) { proxy.scrollTo(h, anchor: .center) }
    }

    /// Resolve the cited chunk → a transcript group anchor + the Gemini-notes accent snippet. The single
    /// SQLite read runs OFF the main thread (it was the synchronous chunk read that pinwheeled the tab
    /// switch / citation tap); the in-memory group match is cheap and stays on the main actor.
    private func resolveHighlight() async {
        highlightSeq += 1; let seq = highlightSeq
        guard let cid = highlightChunkID else { highlightGroupID = nil; citedNoteSnippet = ""; return }
        let store = env.store
        let text = await Task.detached(operation: { (try? store.chunks(ids: [cid]))?.first?.text }).value
        guard highlightSeq == seq else { return }        // a newer highlight superseded this resolve
        guard let text else { highlightGroupID = nil; citedNoteSnippet = ""; return }
        citedNoteSnippet = isNotes ? String(text.prefix(60)) : ""
        let needle = String(text.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
        highlightGroupID = needle.isEmpty ? nil : groups.first(where: { g in
            g.lines.contains(where: { $0.contains(needle) || needle.contains($0.prefix(30)) })
        })?.id
    }

    /// Build a follow-up event draft prefilled from this call — title + its people, defaulting
    /// to the next business hour tomorrow (Calendar v4).
    private func makeFollowUpDraft() -> FollowUpBox {
        let cal = Calendar.current
        let base = cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        let start = cal.date(bySettingHour: 10, minute: 0, second: 0, of: base) ?? base
        let title = meeting.map { "Follow-up: \($0.displayTitle)" } ?? "Follow-up"
        let names = Array(people.prefix(8)).map(\.name)
        return FollowUpBox(draft: EventDraft(title: title, start: start,
                                             end: start.addingTimeInterval(1800), attendees: names))
    }

    private func load() async {
        // All the SQLite reads + transcript grouping happen OFF the main thread (Store is Sendable), then
        // we assign state on the main actor — so opening a long call doesn't freeze the sidebar/navigation.
        let store = env.store, id = meetingID, corrections = env.corrections
        let snap = await Task.detached { MeetingDetailView.buildSnapshot(store: store, meetingID: id, corrections: corrections) }.value
        meeting = snap.meeting
        tasks = snap.tasks
        people = snap.people
        noteLines = snap.noteLines
        groups = snap.groups
        // The call type (isNotes / whether there's a transcript) is only known after this async load, so snap
        // the selected tab to an available one — never strand on a segment the picker no longer shows.
        if !availableTabs.contains(tab) { tab = availableTabs.first ?? .summary }
        recomputeMatches()
        await resolveHighlight()
    }

    nonisolated static func buildSnapshot(store: Store, meetingID: String,
                                          corrections: CorrectionDictionary = CorrectionDictionary()) -> LoadSnapshot {
        var snap = LoadSnapshot(meeting: try? store.meeting(id: meetingID))
        snap.tasks = (try? store.tasks(meetingID: meetingID)) ?? []
        let utts = (try? store.utterances(meetingID: meetingID)) ?? []
        // Gemini NOTES are stored as utterances under a pseudo-speaker — they're a summary, NOT dialogue.
        // Split them off so a merged recording+notes call shows its REAL diarized speakers in the transcript
        // ("who said what when") and the notes land on the Gemini tab instead of polluting it as fake turns.
        let noteUtts = utts.filter { $0.speaker == GeminiNotesParser.pseudoSpeaker }
        var dialogueUtts = utts.filter { $0.speaker != GeminiNotesParser.pseudoSpeaker }
        // A real recording's turns carry MEASURED timestamps. When the call clearly has such dialogue (≥3
        // timed turns), any utterance with NO real timing (tStart ≤ 0) is a merged-in artifact — a folded-in
        // notes/summary line (even one attributed to a person) or an un-diarized blob — not "who said what
        // when". Drop them so only timed dialogue shows. Guarded so a call that legitimately has no timing
        // (pure notes, or diarization that yielded a single block) still shows all of its content.
        let timedTurns = dialogueUtts.filter { ($0.tStart ?? 0) > 0 }.count
        if timedTurns >= 3 {
            dialogueUtts = dialogueUtts.filter { ($0.tStart ?? 0) > 0 }
        }
        let isGemini = snap.meeting?.source == "gmeet_gemini"
        snap.noteLines = !noteUtts.isEmpty ? noteUtts.map(\.text)
            : (isGemini ? ((try? store.transcript(meetingID: meetingID)) ?? []).map(\.text) : [])
        // People populate for EVERY source (final-audit P6 MED: Gemini notes carry a roster
        // too — needed for schedule-follow-up attendees + the People chips). Pass the call's real diarized
        // speakers as the trusted full-name set so a bare "Riley" only folds into "Riley Novak" when Riley
        // Good actually spoke — never merging two different people who happen to share a first name.
        let speakerNames = Set(dialogueUtts.compactMap {
            $0.speaker?.trimmingCharacters(in: .whitespaces).lowercased()
        }.filter { !$0.isEmpty })
        snap.people = EntityExtractor.clean((try? store.entities(meetingID: meetingID)) ?? [],
                                            trustedFullNames: speakerNames)
            .filter { $0.kind == .person && $0.count >= 2 }.prefix(10).map { $0 }
        // A pure Gemini-notes call has no verbatim transcript — the Gemini tab shows the notes; no speakers.
        if isGemini { snap.groups = []; return snap }
        // Apply the vocabulary corrections at DISPLAY time (idempotent with the ingest apply-pass), so a
        // just-added correction shows in THIS call on the next reload — the "it tunes the system" feedback —
        // without a store migration (retroactive store re-correct is a later, search-consistency phase).
        // Compile the corrector ONCE and reuse it across every line (audit LOW).
        let corrector = corrections.makeApplicator()
        let rows: [(speaker: String, t: Double?, inferred: Bool, text: String)]
        if dialogueUtts.isEmpty {
            rows = ((try? store.transcript(meetingID: meetingID)) ?? [])
                .map { (speaker: $0.speaker ?? "—", t: $0.tStart, inferred: false, text: corrector.apply(to: $0.text)) }
        } else {
            rows = dialogueUtts.map { (speaker: $0.speaker ?? "—", t: $0.tStart, inferred: $0.isInferred, text: corrector.apply(to: $0.text)) }
        }
        // Normalize speaker labels for display: raw diarization tokens (SPEAKER_00) + empty/"—"/"Unknown"
        // fallbacks become clean "Speaker 1/2/3"; real names pass through. Grouping keys on the display name.
        let nameMap = SpeakerResolver.displayNames(for: rows.map(\.speaker))
        var result: [TurnGroup] = []
        for r in rows {
            let speaker = nameMap[r.speaker] ?? r.speaker
            if let last = result.last, last.speaker == speaker {
                result[result.count - 1].lines.append(r.text)
            } else {
                result.append(TurnGroup(id: result.count, speaker: speaker, tStart: r.t,
                                        isInferred: r.inferred, lines: [r.text]))
            }
        }
        snap.groups = result
        return snap
    }
}

/// Identifiable box so the schedule-follow-up editor can present via `.sheet(item:)`.
struct FollowUpBox: Identifiable {
    let id = UUID()
    let draft: EventDraft
}
