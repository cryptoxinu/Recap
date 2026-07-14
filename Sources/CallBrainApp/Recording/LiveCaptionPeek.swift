import SwiftUI
import CallBrainAppCore

/// The live transcript peek when Google Meet CC captions are relaying during a recording (T2 slice 2).
///
/// Unlike `LiveTranscriptPeek` (on-device WhisperKit, which can only label `You`/`Them`), captions carry
/// the REAL participant name for every turn — so this shows the accurate, named conversation as it happens,
/// which is exactly what the founder asked for ("it doesn't know who is talking… who is speaking when").
struct LiveCaptionPeek: View {
    let turns: [CaptionTurn]

    // Recent tail, consecutive same-speaker turns merged into one readable block. Bounded so a long call's
    // eager VStack stays cheap (same guard as LiveTranscriptPeek).
    private var blocks: [CaptionBlock] { CaptionBlock.group(turns.suffix(120)) }

    /// Everyone heard on the call so far, first-seen order (T4 — "who's on the call").
    private var roster: [String] {
        var seen = Set<String>(); var out: [String] = []
        for t in turns {
            let name = t.speaker.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            out.append(name)
        }
        return out
    }
    /// Who spoke most recently — surfaced live as "who's speaking" (T4).
    private var activeSpeaker: String? {
        blocks.last?.speaker
    }

    @State private var pinnedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if !roster.isEmpty { rosterBar }
            ZStack {
                if blocks.isEmpty { waiting } else { scroll }
            }
            // Taller, adaptive pane so more of the conversation is readable at once (the old fixed 150pt
            // showed ~2 turns). Bounded so the left column's other cards still fit.
            .frame(minHeight: 210, maxHeight: 340)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.hairline))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "captions.bubble.fill")
                .font(.cbCaption.weight(.semibold))
                .foregroundStyle(Theme.success)
            Text("Google Meet captions")
                .font(.cbCaption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
            Text("accurate · real names")
                .font(.cbFootnote.weight(.medium))
                .foregroundStyle(Theme.success)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Theme.success.opacity(0.14)))
        }
    }

    /// "Who's on the call" + a live "● <name> speaking" marker (T4). Names carry the same per-participant
    /// tint as the transcript so the same person reads the same colour throughout.
    private var rosterBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.2.fill").font(.system(size: 10)).foregroundStyle(.tertiary)
            ForEach(roster.prefix(6), id: \.self) { name in
                HStack(spacing: 3) {
                    if name == activeSpeaker {
                        Circle().fill(Theme.speakerColor(name)).frame(width: 5, height: 5)
                    }
                    Text(name)
                        .font(.system(size: 11, weight: name == activeSpeaker ? .semibold : .regular))
                        .foregroundStyle(name == activeSpeaker ? Theme.speakerColor(name) : Theme.textSecondary)
                }
            }
            if roster.count > 6 {
                Text("+\(roster.count - 6)").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
    }

    private var waiting: some View {
        VStack(spacing: 8) {
            Image(systemName: "captions.bubble")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.success.opacity(0.6))
            Text("Waiting for Meet captions…")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Text("Turn on captions (CC) in Google Meet.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Space.m) {
                    ForEach(blocks) { block in
                        CaptionBlockRow(block: block).id(block.id)
                    }
                }
                .scrollTargetLayout()
                .padding(.trailing, 2)
            }
            .scrollPosition(id: $pinnedID, anchor: .bottom)
            .onAppear { if let last = blocks.last?.id { proxy.scrollTo(last, anchor: .bottom) } }
            .onChange(of: blocks) { _, new in
                guard let last = new.last?.id else { return }
                withAnimation(Theme.smooth) { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
    }
}

/// One speaker's merged run of caption turns.
private struct CaptionBlock: Identifiable, Equatable {
    let id: String
    let speaker: String
    let text: String

    static func group(_ turns: ArraySlice<CaptionTurn>) -> [CaptionBlock] {
        var out: [CaptionBlock] = []
        var index = 0
        for turn in turns {
            let speaker = turn.speaker.trimmingCharacters(in: .whitespaces)
            let text = turn.text.trimmingCharacters(in: .whitespaces)
            guard !speaker.isEmpty, !text.isEmpty else { continue }
            if let last = out.last, last.speaker == speaker {
                out[out.count - 1] = CaptionBlock(id: last.id, speaker: speaker, text: last.text + " " + text)
            } else {
                out.append(CaptionBlock(id: "\(index)#\(speaker)", speaker: speaker, text: text))
                index += 1
            }
        }
        return out
    }
}

/// One speaker's turn as a Google-Meet-style row: a tinted initials avatar + the real name + the words
/// in a speaker-tinted bubble, so a group call reads apart at a glance ("who is talking" — the founder's
/// ask). Uses the canonical, dark-mode-tuned `Theme.speakerColor` (a stable hue per participant).
private struct CaptionBlockRow: View {
    let block: CaptionBlock

    private var tint: Color { Theme.speakerColor(block.speaker) }

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            SpeakerAvatar(name: block.speaker, tint: tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(block.speaker)
                    .font(.cbCaption.weight(.semibold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(block.text)
                    .font(.cbBody)
                    .foregroundStyle(Theme.textPrimary)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading) // bound width so long lines wrap, not clip
                    .padding(.horizontal, Space.m)
                    .padding(.vertical, Space.s)
                    .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                        .fill(Theme.surfaceElevated))
                    .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                        .strokeBorder(tint.opacity(0.32), lineWidth: 1))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

