import SwiftUI
import CallBrainCore

/// Calendar v4 — natural-language quick-add. Type "lunch w/ Sam fri 1pm" and press Return;
/// EventDraftParser turns it into a draft that opens in the editor prefilled (so a wrong guess
/// is confirmed, never silently saved). Unparseable text still opens the editor with the text
/// as the title.
struct QuickAddField: View {
    let onDraft: (EventDraft) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar.badge.plus").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("", text: $text,
                      prompt: Text("Quick add — e.g. “lunch w/ Sam fri 1pm”").foregroundStyle(.tertiary))
                .textFieldStyle(.plain).font(.system(size: 13))
                .focused($focused)
                .onSubmit(submit)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.cardFill.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? Theme.accent.opacity(0.5) : Theme.hairline))
        .frame(maxWidth: 420)
    }

    private func submit() {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { text = ""; return }
        let draft = EventDraftParser.parse(raw)
            ?? EventDraft(title: raw, start: defaultStart(), end: defaultStart().addingTimeInterval(1800))
        text = ""
        onDraft(draft)
    }

    private func defaultStart() -> Date {
        let cal = Calendar.current
        let h = cal.component(.hour, from: Date())
        return cal.date(bySettingHour: min(h + 1, 23), minute: 0, second: 0, of: Date()) ?? Date()
    }
}
