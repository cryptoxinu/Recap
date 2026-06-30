import SwiftUI
import CallBrainCore

/// Surfaces *suggested* near-duplicate meetings (Phase 6) — heuristic, never auto-merged. The most
/// common case: the same call captured twice (Gemini notes + a transcript). The user deletes one or
/// dismisses the suggestion (dismissals persist so they don't re-appear).
struct DuplicateReviewView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var suggestions: [DuplicateSuggestion] = []
    @State private var confirmDelete: (id: String, title: String)?

    private static let dismissedKey = "callbrain.dismissedDuplicates"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Review possible duplicates").font(.title3).bold()
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()
            Divider()
            if suggestions.isEmpty {
                ContentUnavailableView("No duplicates to review", systemImage: "checkmark.circle",
                    description: Text("CallBrain didn't find any likely duplicate calls."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(suggestions) { s in
                            card(s).transition(.opacity.combined(with: .scale(scale: 0.96)))
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(minWidth: 640, minHeight: 460)
        .task { reload() }
        .alert("Delete this call?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let d = confirmDelete { try? env.store.deleteMeeting(id: d.id); reload(); env.refreshReminders() }
                confirmDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        } message: {
            Text("“\(confirmDelete?.title ?? "")” will be removed — its transcript/notes, tasks, this call's "
                 + "chats, and any saved excerpts in other chats. This can't be undone.")
        }
    }

    private func card(_ s: DuplicateSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.on.rectangle.angled").foregroundStyle(.orange)
                Text(s.reason).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(s.score * 100))% match").font(.caption).foregroundStyle(.tertiary)
            }
            HStack(spacing: 12) {
                meetingCol(s.a)
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(.tertiary)
                meetingCol(s.b)
            }
            HStack {
                Spacer()
                Button("Not a duplicate") { dismissPair(s) }.buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
    }

    private func meetingCol(_ m: MeetingMeta) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(m.displayTitle).font(.body.weight(.medium)).lineLimit(2)   // the meaningful AI title
            // Show the original date-stamp title too, so it's clear which raw call this is.
            if m.smartTitle?.isEmpty == false, m.title != m.displayTitle {
                Text(m.title).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            Text("\(m.date) · \(sourceLabel(m.source))").font(.caption).foregroundStyle(.secondary)
            Button(role: .destructive) { confirmDelete = (m.id, m.displayTitle) } label: {
                Label("Delete this one", systemImage: "trash").font(.caption)
            }
            .buttonStyle(.borderless).padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sourceLabel(_ s: String) -> String {
        switch s {
        case "gmeet_gemini": "Google Meet notes"; case "gmeet_local", "gmeet_cloud": "Recording"
        case "fireflies": "Fireflies"; case "fathom": "Fathom"; case "paste": "Pasted"; default: s
        }
    }

    private func reload() {
        let dismissed = Set(UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? [])
        let metas = (try? env.store.meetingMetas()) ?? []
        let next = DuplicateDetector.suggestions(metas).filter { !dismissed.contains($0.id) }
        withAnimation(Theme.springy) { suggestions = next }
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
        return DuplicateDetector.suggestions(metas).filter { !dismissed.contains($0.id) }.count
    }
}
