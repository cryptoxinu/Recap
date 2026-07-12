import SwiftUI
import CallBrainCore

/// Surfaces *suggested* near-duplicate meetings (Phase 6) — heuristic, never auto-merged. The most
/// common case: the same call captured twice (Gemini notes + a transcript). The user deletes one or
/// dismisses the suggestion (dismissals persist so they don't re-appear).
struct DuplicateReviewView: View {
    /// When true (from the Meetings banner "Clean up with AI"), jump straight to the cleanup sheet.
    var autoCleanup = false
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var suggestions: [DuplicateSuggestion] = []
    @State private var linkCandidates: [CrossSourceLinker.Pair] = []   // notes↔recording (8.1)
    @State private var mergeError: String?
    @State private var confirmDelete: (id: String, title: String)?
    @State private var deleteError: String?
    @State private var reloadSeq = 0                  // drops out-of-order off-main dup scans
    @State private var showCleanup = false            // one-click AI cleanup sheet

    private static let dismissedKey = "callbrain.dismissedDuplicates"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Review possible duplicates").font(.cbTitle).foregroundStyle(Theme.textPrimary)
                Spacer()
                // One-click: let the AI keep the richest copy of each call and merge the rest
                // (content-conserving — nothing deleted). Shown only when there's something to clean.
                if !suggestions.isEmpty || !linkCandidates.isEmpty {
                    Button { showCleanup = true } label: {
                        Label("Clean up with AI", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .help("Keep the highest-quality copy of each call and combine the rest — nothing is deleted.")
                }
                Button("Done") { dismiss() }
            }
            .padding()
            Divider()
            if suggestions.isEmpty && linkCandidates.isEmpty {
                ContentUnavailableView("No duplicates to review", systemImage: "checkmark.circle",
                    description: Text("Recap didn't find any likely duplicate calls."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(linkCandidates, id: \.gemini.id) { c in
                            linkCard(c).transition(.opacity.combined(with: .scale(scale: 0.96)))
                        }
                        ForEach(suggestions) { s in
                            card(s).transition(.opacity.combined(with: .scale(scale: 0.96)))
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(minWidth: 640, minHeight: 460)
        .task {
            reload()
            if autoCleanup { showCleanup = true }
        }
        .sheet(isPresented: $showCleanup) {
            DuplicateCleanupSheet { merged in
                if merged > 0 { env.titlesRevision &+= 1; reload() }
            }
            .environment(env)
        }
        .alert("Delete this call?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) {
                guard let d = confirmDelete else { return }
                confirmDelete = nil
                // Route through the async wrapper so the heavy cascade delete + citation scrub runs OFF the
                // main thread (never freezes the window on a large library) and surfaces failure honestly.
                Task { @MainActor in
                    if await env.deleteMeetingAsync(d.id) { reload() }
                    else { deleteError = d.title }
                }
            }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        } message: {
            Text("“\(confirmDelete?.title ?? "")” will be removed — its transcript/notes, tasks, this call's "
                 + "chats, and any saved excerpts in other chats. This can't be undone.")
        }
        .alert("Couldn't merge", isPresented: Binding(get: { mergeError != nil }, set: { if !$0 { mergeError = nil } })) {
            Button("OK", role: .cancel) { mergeError = nil }
        } message: {
            Text("“\(mergeError ?? "")” couldn't be merged. Try again.")
        }
        .alert("Couldn't delete", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("OK", role: .cancel) { deleteError = nil }
        } message: {
            Text("“\(deleteError ?? "")” couldn't be deleted. Try again.")
        }
    }

    /// Notes + recording of the SAME call (Task 8.1) — one-tap merge through the audited
    /// StoreMerge path (chunks/tasks/citations conserved).
    private func linkCard(_ c: CrossSourceLinker.Pair) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: Space.s) {
                Image(systemName: "arrow.triangle.merge").foregroundStyle(Theme.accent)
                Text("Notes + recording of the same call").font(.cbCallout).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(c.transcript.date).font(.cbCaption).foregroundStyle(Theme.textTertiary)
            }
            HStack(spacing: Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.gemini.displayTitle).font(.cbBody.weight(.medium)).foregroundStyle(Theme.textPrimary).lineLimit(2)
                    Text("Google Meet notes").font(.cbCaption).foregroundStyle(Theme.textSecondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "plus").foregroundStyle(Theme.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.transcript.displayTitle).font(.cbBody.weight(.medium)).foregroundStyle(Theme.textPrimary).lineLimit(2)
                    Text("Recording").font(.cbCaption).foregroundStyle(Theme.textSecondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: Space.s) {
                Spacer()
                Button("Keep separate") { dismissLink(c) }.buttonStyle(.bordered)
                Button("Merge into one call") { merge(c) }.buttonStyle(.borderedProminent).tint(Theme.accent)
            }
        }
        .padding(Space.l)
        .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Theme.hairline))
    }

    private func merge(_ c: CrossSourceLinker.Pair) {
        let store = env.store
        Task { @MainActor in
            let ok = await Task.detached {
                (try? store.mergeMeetings(loserID: c.gemini.id, survivorID: c.transcript.id)) != nil
            }.value
            if ok { env.titlesRevision &+= 1; reload() } else { mergeError = c.gemini.displayTitle }
        }
    }

    /// Merge a heuristic near-duplicate pair (e.g. the recurring Fathom + Google-Meet capture of the same
    /// morning sync). Content-conserving: the survivor gains the loser's transcript/notes/tasks/citations,
    /// then the loser meeting is removed. Same audited StoreMerge path as the notes↔recording linker.
    private func mergePair(loser: MeetingMeta, survivor: MeetingMeta) {
        let store = env.store
        Task { @MainActor in
            let ok = await Task.detached {
                (try? store.mergeMeetings(loserID: loser.id, survivorID: survivor.id)) != nil
            }.value
            if ok { env.titlesRevision &+= 1; reload() } else { mergeError = loser.displayTitle }
        }
    }

    private func dismissLink(_ c: CrossSourceLinker.Pair) {
        var dismissed = Set(UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? [])
        dismissed.insert([c.gemini.id, c.transcript.id].sorted().joined(separator: "|"))
        UserDefaults.standard.set(Array(dismissed), forKey: Self.dismissedKey)
        reload()
    }

    private func card(_ s: DuplicateSuggestion) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                Image(systemName: "rectangle.on.rectangle.angled").foregroundStyle(Theme.warning)
                Text(s.reason).font(.cbCallout).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("\(Int(s.score * 100))% match").font(.cbCaption.weight(.medium)).foregroundStyle(Theme.textTertiary)
            }
            HStack(spacing: Space.m) {
                meetingCol(s.a)
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(Theme.textTertiary)
                meetingCol(s.b)
            }
            HStack(spacing: Space.s) {
                Spacer()
                Button("Not a duplicate") { dismissPair(s) }.buttonStyle(.bordered)
                // The recurring case (Fathom + Google-Meet of one morning sync): combine into one call,
                // keeping everything. Menu lets you pick which title/date survives; content is conserved either way.
                Menu {
                    Button { mergePair(loser: s.b, survivor: s.a) } label: { Text("Keep “\(s.a.displayTitle)”") }
                    Button { mergePair(loser: s.a, survivor: s.b) } label: { Text("Keep “\(s.b.displayTitle)”") }
                } label: {
                    Label("Merge into one", systemImage: "arrow.triangle.merge")
                }
                .menuStyle(.button)
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                .fixedSize()
                .help("Combine into one call — keeps the transcript, notes, tasks, and citations from both.")
            }
        }
        .padding(Space.l)
        .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Theme.hairline))
    }

    private func meetingCol(_ m: MeetingMeta) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(m.displayTitle).font(.cbBody.weight(.medium)).foregroundStyle(Theme.textPrimary).lineLimit(2)   // the meaningful AI title
            // Show the original date-stamp title too, so it's clear which raw call this is.
            if m.smartTitle?.isEmpty == false, m.title != m.displayTitle {
                Text(m.title).font(.cbCaption).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            Text("\(m.date) · \(sourceLabel(m.source))").font(.cbCaption).foregroundStyle(Theme.textSecondary)
            Button(role: .destructive) { confirmDelete = (m.id, m.displayTitle) } label: {
                Label("Delete this one", systemImage: "trash").font(.cbCaption)
            }
            .buttonStyle(.borderless).padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sourceLabel(_ s: String) -> String {
        switch s {
        case "gmeet_gemini": "Google Meet notes"; case "gmeet_local", "gmeet_cloud": "Recording"
        case "gmeet_captions": "Meet captions"
        case "fireflies": "Fireflies"; case "fathom": "Fathom"; case "paste": "Pasted"; default: s
        }
    }

    private func reload() {
        // The meetingMetas read + the O(n²) DuplicateDetector scan run OFF the main thread (audit MED — the
        // delete moved off-main but this reload was still blocking); a sequence guard drops stale results.
        let dismissed = Set(UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? [])
        let store = env.store
        reloadSeq += 1; let seq = reloadSeq
        Task { @MainActor in
            let (next, links) = await Task.detached { () -> ([DuplicateSuggestion], [CrossSourceLinker.Pair]) in
                let dups = DuplicateDetector.suggestions((try? store.meetingMetas()) ?? []).filter { !dismissed.contains($0.id) }
                // Task 8.1: notes↔recording pairs from FUTURE imports surface here for one-tap
                // MERGE (the conservative linker; never auto-merged).
                let l = ((try? CrossSourceLinker.candidates(store: store)) ?? [])
                    .filter { !dismissed.contains([$0.gemini.id, $0.transcript.id].sorted().joined(separator: "|")) }
                return (dups, l)
            }.value
            guard reloadSeq == seq else { return }
            withAnimation(Theme.springy) { suggestions = next; linkCandidates = links }
        }
    }

    private func dismissPair(_ s: DuplicateSuggestion) {
        var dismissed = Set(UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? [])
        dismissed.insert(s.id)
        UserDefaults.standard.set(Array(dismissed), forKey: Self.dismissedKey)
        reload()
    }
}

/// How many duplicate suggestions exist right now (for the Meetings banner).
enum DuplicateScan {
    static func count(_ store: Store) -> Int {
        let dismissed = Set(UserDefaults.standard.stringArray(forKey: "callbrain.dismissedDuplicates") ?? [])
        let metas = (try? store.meetingMetas()) ?? []
        let dups = DuplicateDetector.suggestions(metas).filter { !dismissed.contains($0.id) }.count
        // Linker pairs count too (gate MED: a future notes↔recording pair must raise the banner
        // that leads to the review sheet, not sit invisible inside it).
        let links = ((try? CrossSourceLinker.candidates(store: store)) ?? [])
            .filter { !dismissed.contains([$0.gemini.id, $0.transcript.id].sorted().joined(separator: "|")) }.count
        return dups + links
    }
}
