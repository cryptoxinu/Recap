import SwiftUI
import CallBrainCore

/// One-click "Clean up duplicates with AI" (2026-07-09). Analyzes the current duplicate
/// suggestions + notes↔recording links, ranks each copy by quality, and proposes a
/// content-conserving plan: keep the richest copy of every call and MERGE the rest into it
/// (audited `Store.mergeMeetings` — transcript/notes/tasks/citations conserved). Nothing is
/// deleted, so applying is safe. The founder sees WHY each keeper won before confirming.
struct DuplicateCleanupSheet: View {
    /// Called with the number of duplicates actually merged away, so the parent reloads.
    var onFinished: (Int) -> Void

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .analyzing

    private static let dismissedKey = "callbrain.dismissedDuplicates"

    enum Phase: Equatable {
        case analyzing
        case nothing                                   // nothing confident enough to auto-merge
        case plan(DuplicateResolver.CleanupPlan)
        case applying(done: Int, total: Int)
        case finished(merged: Int, failed: Int)
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 560, minHeight: 420)
        .task { await analyze() }
    }

    private var header: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "sparkles").foregroundStyle(Theme.accent)
            Text("Clean up duplicates").font(.cbTitle).foregroundStyle(Theme.textPrimary)
            Spacer()
            if case .applying = phase {} else {
                Button(isTerminal ? "Done" : "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding()
    }

    private var isTerminal: Bool {
        switch phase { case .finished, .nothing, .failed: return true; default: return false }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .analyzing:
            centered {
                ProgressView().controlSize(.small)
                Text("Analyzing your duplicates…").font(.cbBody).foregroundStyle(Theme.textSecondary)
            }
        case .nothing:
            centered {
                Image(systemName: "checkmark.seal").font(.system(size: 30)).foregroundStyle(Theme.success)
                Text("Nothing clear-cut to auto-merge").font(.cbBody.weight(.medium)).foregroundStyle(Theme.textPrimary)
                Text("The remaining pairs aren't a confident match — review them by hand so nothing is combined by mistake.")
                    .font(.cbCallout).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
        case .plan(let plan):
            planView(plan)
        case .applying(let done, let total):
            centered {
                ProgressView(value: Double(done), total: Double(max(total, 1))).frame(width: 260)
                Text("Merging \(done) of \(total)…").font(.cbBody).foregroundStyle(Theme.textSecondary)
            }
        case .finished(let merged, let failed):
            centered {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 34)).foregroundStyle(Theme.success)
                Text(merged == 0 ? "Nothing to clean up" : "Cleaned up \(merged) duplicate\(merged == 1 ? "" : "s")")
                    .font(.cbBody.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                Text("The richer copy of each call was kept — its transcript, notes, and tasks are all intact.")
                    .font(.cbCallout).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 420)
                if failed > 0 {
                    Text("\(failed) couldn't be merged and were left as-is.")
                        .font(.cbCaption).foregroundStyle(Theme.warning)
                }
            }
        case .failed(let msg):
            centered {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 28)).foregroundStyle(Theme.warning)
                Text("Couldn't analyze duplicates").font(.cbBody.weight(.medium)).foregroundStyle(Theme.textPrimary)
                Text(msg).font(.cbCaption).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 400)
            }
        }
    }

    private func planView(_ plan: DuplicateResolver.CleanupPlan) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("AI will merge \(plan.merges.count) duplicate\(plan.merges.count == 1 ? "" : "s"), always keeping the richer copy. **Nothing is deleted** — each call's transcript, notes, and tasks are combined into one.")
                        .font(.cbCallout).foregroundStyle(Theme.textSecondary)
                        .padding(.bottom, 2)
                    ForEach(plan.merges) { m in mergeRow(m) }
                    if plan.reviewCount > 0 {
                        Label("\(plan.reviewCount) other pair\(plan.reviewCount == 1 ? "" : "s") aren't a confident match — left for you to review by hand.",
                              systemImage: "hand.raised")
                            .font(.cbCaption).foregroundStyle(Theme.textTertiary)
                            .padding(.top, 4)
                    }
                }
                .padding()
            }
            Divider()
            HStack(spacing: Space.s) {
                Spacer()
                Button("Not now") { dismiss() }.buttonStyle(.bordered)
                Button {
                    Task { await apply(plan) }
                } label: {
                    Label("Clean up all (\(plan.merges.count))", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent).keyboardShortcut(.defaultAction)
            }
            .padding()
        }
    }

    private func mergeRow(_ m: DuplicateResolver.PlannedMerge) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Space.s) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(Theme.success)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Keep “\(m.survivorTitle)”").font(.cbBody.weight(.medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text(m.survivorDetail).font(.cbCaption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
            HStack(spacing: Space.s) {
                Image(systemName: "arrow.triangle.merge").font(.system(size: 13)).foregroundStyle(Theme.textTertiary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Fold in “\(m.loserTitle)”").font(.cbCallout).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    Text(m.loserDetail).font(.cbCaption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
            }
            Text(m.reason).font(.cbCaption).foregroundStyle(Theme.textTertiary)
                .padding(.leading, 20)
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Theme.hairline))
    }

    @ViewBuilder private func centered<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(spacing: 10) { c() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
    }

    // MARK: - logic

    private func analyze() async {
        guard case .analyzing = phase else { return }
        let store = env.store
        let dismissed = Set(UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? [])
        let result: Result<DuplicateResolver.CleanupPlan, Error> = await Task.detached {
            do {
                let metas = (try? store.meetingMetas()) ?? []
                let sugs = DuplicateDetector.suggestions(metas).filter { !dismissed.contains($0.id) }
                let links = ((try? CrossSourceLinker.candidates(store: store)) ?? [])
                    .filter { !dismissed.contains([$0.gemini.id, $0.transcript.id].sorted().joined(separator: "|")) }

                var edges: [DuplicateResolver.Edge] = []
                edges += links.map {
                    DuplicateResolver.Edge(a: $0.gemini.id, b: $0.transcript.id,
                                           crossSource: $0.gemini.source != $0.transcript.source,
                                           score: 1.0, kind: .link)
                }
                edges += sugs.map {
                    DuplicateResolver.Edge(a: $0.a.id, b: $0.b.id,
                                           crossSource: $0.a.source != $0.b.source,
                                           score: $0.score, kind: .suggestion)
                }
                let ids = Array(Set(edges.flatMap { [$0.a, $0.b] }))
                let quality = try store.meetingQualitySignals(ids: ids)
                return .success(DuplicateResolver.plan(edges: edges, quality: quality))
            } catch { return .failure(error) }
        }.value

        switch result {
        case .success(let plan):
            phase = plan.isEmpty ? .nothing : .plan(plan)
        case .failure(let err):
            phase = .failed(err.localizedDescription)
        }
    }

    private func apply(_ plan: DuplicateResolver.CleanupPlan) async {
        let store = env.store
        let total = plan.merges.count
        var merged = 0, failed = 0
        for (i, m) in plan.merges.enumerated() {
            phase = .applying(done: i, total: total)
            let ok = await Task.detached {
                (try? store.mergeMeetings(loserID: m.loserID, survivorID: m.survivorID)) != nil
            }.value
            if ok { merged += 1 } else { failed += 1 }
        }
        env.titlesRevision &+= 1
        onFinished(merged)
        phase = .finished(merged: merged, failed: failed)
    }
}
