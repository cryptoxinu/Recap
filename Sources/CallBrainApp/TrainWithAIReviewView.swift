import SwiftUI
import CallBrainCore

/// "Train with AI" review (#42): the AI proposes likely mis-transcribed terms; the user APPROVES each
/// (nothing is auto-applied). Approved terms enter the growing dictionary and fix every future call.
struct TrainWithAIReviewView: View {
    let proposals: [AskEngine.MinedCorrection]
    let onApprove: ([AskEngine.MinedCorrection]) -> Void
    let cancel: () -> Void

    @State private var approved: Set<String>

    init(proposals: [AskEngine.MinedCorrection],
         onApprove: @escaping ([AskEngine.MinedCorrection]) -> Void,
         cancel: @escaping () -> Void) {
        self.proposals = proposals
        self.onApprove = onApprove
        self.cancel = cancel
        _approved = State(initialValue: Set(proposals.map(\.id)))   // all checked by default
    }

    private var approvedList: [AskEngine.MinedCorrection] { proposals.filter { approved.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars").foregroundStyle(Theme.accent)
                Text("AI-suggested corrections").font(.headline)
            }

            if proposals.isEmpty {
                emptyState
            } else {
                Text("Review what the AI thinks was mis-transcribed. Approved terms are learned for every "
                     + "future call — nothing is applied without your OK.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    VStack(spacing: 6) { ForEach(proposals) { row($0) } }
                }
                .frame(maxHeight: 320)
            }

            HStack {
                if !proposals.isEmpty {
                    Button(approved.count == proposals.count ? "Deselect all" : "Select all") {
                        approved = approved.count == proposals.count ? [] : Set(proposals.map(\.id))
                    }
                    .buttonStyle(.plain).font(.callout).foregroundStyle(Theme.accent)
                }
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button(proposals.isEmpty ? "Done" : "Add \(approvedList.count)") {
                    proposals.isEmpty ? cancel() : onApprove(approvedList)
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(!proposals.isEmpty && approvedList.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func row(_ c: AskEngine.MinedCorrection) -> some View {
        let on = approved.contains(c.id)
        return Button {
            if on { approved.remove(c.id) } else { approved.insert(c.id) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(on ? Theme.accent : .secondary).font(.system(size: 15)).padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("“\(c.heard)”").foregroundStyle(.secondary)
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                        Text(c.shouldBe).fontWeight(.medium)
                    }
                    .font(.callout)
                    if !c.reason.isEmpty {
                        Text(c.reason).font(.caption).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(on ? Theme.accent.opacity(0.06) : Theme.cardFill))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(on ? Theme.accent.opacity(0.25) : Theme.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal").font(.title2).foregroundStyle(Theme.success)
            Text("No new mis-transcriptions found — this call's vocabulary looks clean.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
    }
}
