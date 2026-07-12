import SwiftUI
import CallBrainCore

/// Click-to-correct (#42): tap the word that was heard wrong in a transcript line, type what it should
/// be, and Recap learns it for every future call (ASR bias + the deterministic apply-pass). Directly
/// serves the founder's ask — "click on a word in the transcript and say we meant this and it tunes."
struct FixWordSheet: View {
    let context: String
    @Binding var wrong: String
    @Binding var right: String
    let onSave: () -> Void
    let cancel: () -> Void

    /// Trim ONLY true edge delimiters (sentence punctuation, quotes, brackets) — never symbols that are
    /// part of a term like "$SOL" or "C#" (audit MED: stripping `$`/`#` produced bad entries like `$$SOL`).
    private static let edgeDelimiters = CharacterSet(charactersIn: ".,!?;:\"'“”‘’()[]{}…")

    /// The line split into tappable word chips (edge punctuation trimmed, deduped-in-order, and BOTH the
    /// scan length and per-token length capped so one giant no-whitespace line can't blow up the sheet).
    private var words: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for token in context.prefix(4000).split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            guard token.count <= 40 else { continue }   // skip a pathological no-space blob token
            let w = String(token).trimmingCharacters(in: Self.edgeDelimiters)
            let key = w.lowercased()
            guard w.count > 1, !seen.contains(key) else { continue }
            seen.insert(key); out.append(w)
            if out.count >= 40 { break }
        }
        return out
    }

    private var trimmedWrong: String { wrong.trimmingCharacters(in: .whitespaces) }

    /// The "wrong" term is a common English word / too short — correcting it globally would corrupt
    /// unrelated transcripts. Corrections are for names + jargon only.
    private var isRisky: Bool { !trimmedWrong.isEmpty && CorrectionDictionary.isRiskyWrong(trimmedWrong) }

    private var canSave: Bool {
        let w = trimmedWrong, r = right.trimmingCharacters(in: .whitespaces)
        return !w.isEmpty && !r.isEmpty && w.lowercased() != r.lowercased() && !isRisky
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Fix a mis-transcribed word").font(.headline)
            Text("Tap the word that was heard wrong, then type what it should be. Recap learns it for every future call — no re-training.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if !words.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 54), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(Array(words.enumerated()), id: \.offset) { _, w in
                        Button { wrong = w } label: {
                            Text(w).font(.system(size: 12)).lineLimit(1)
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(Capsule().fill(wrong == w ? Theme.accent.opacity(0.18) : Theme.cardFill))
                                .overlay(Capsule().strokeBorder(wrong == w ? Theme.accent : Theme.hairline))
                                .foregroundStyle(wrong == w ? Theme.accent : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxHeight: 130)
            }

            HStack(alignment: .bottom, spacing: 10) {
                field("Heard", text: $wrong, prompt: "wrong word")
                Image(systemName: "arrow.right").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary).padding(.bottom, 6)
                field("Should be", text: $right, prompt: "correct term")
            }

            if isRisky {
                Label("“\(trimmedWrong)” looks like a common word — corrections are for names and jargon "
                      + "so unrelated calls aren't changed.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Save", action: onSave).buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction).disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(0.5)
                .foregroundStyle(.tertiary)
            TextField(prompt, text: text).textFieldStyle(.roundedBorder).frame(maxWidth: .infinity)
        }
    }
}
