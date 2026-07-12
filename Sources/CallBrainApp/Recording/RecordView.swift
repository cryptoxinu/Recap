import SwiftUI
import CallBrainCore
import CallBrainAppCore

/// The recording panel — start/stop a live meeting recording, name it, jot notes while it
/// runs, and watch the level meter. On stop it hands off to the transcription pipeline and the
/// meeting appears in Meetings with a full transcript + AI summary.
struct RecordView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    var presetTitle: String? = nil
    var linkedEventID: String? = nil

    private var rec: RecordingModel { env.recording }

    var body: some View {
        @Bindable var rec = env.recording
        // No in-content title/close — the window's own title bar ("Record meeting") + traffic-light close
        // already do that. Idle/processing states CENTER so a small form doesn't float in a huge window;
        // the recording canvas fills from the top.
        VStack(alignment: .leading, spacing: 12) {
            switch rec.phase {
            case .idle:      idleControls(rec)
            case .recording: liveControls(rec)
            case .processing: processingView
            }
            if let e = rec.errorText {
                VStack(alignment: .leading, spacing: 8) {
                    Label(e, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(Theme.warning)
                    // A denied recording permission is one tap to fix — jump straight to the right pane.
                    if let issue = rec.permissionIssue {
                        Button {
                            PrivacySettings.open(issue)
                        } label: {
                            Label(issue.buttonTitle, systemImage: "gearshape").font(.system(size: 12))
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
        }
        .padding(rec.phase == .recording ? 20 : 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: rec.phase == .recording ? .topLeading : .center)
        .onDisappear {
            // The window closed — reset the open signal so a later trigger reopens it, and drop any
            // stale calendar preset if we never actually recorded.
            env.recordSheetShown = false
            env.recording.clearPresetIfIdle()
        }
    }

    private var processingView: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text("Transcribing your recording…").font(.system(size: 15, weight: .medium))
            Text("It'll appear in Meetings when it's done.").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func idleControls(_ rec: RecordingModel) -> some View {
        @Bindable var rec = rec
        // The start form stays a comfortable width even in a wide resized window.
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "record.circle.fill").font(.system(size: 16)).foregroundStyle(Theme.danger)
                Text("Record a meeting").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            }
            .padding(.bottom, 2)
            TextField("Meeting title", text: $rec.title,
                      prompt: Text(presetTitle ?? "e.g. Partner sync").foregroundStyle(.tertiary))
                .textFieldStyle(.roundedBorder)
            Toggle(isOn: $rec.includeSystemAudio) {
                Text("Capture the other participants (system audio)").font(.system(size: 12))
            }
            .toggleStyle(.checkbox)
            Toggle(isOn: $rec.micGateEnabled) {
                Text("Only record my mic while I'm speaking (skips silence + background noise)")
                    .font(.system(size: 12))
            }
            .toggleStyle(.checkbox)
            templatePicker(rec)
            Text("First time, macOS will ask for microphone" +
                 (rec.includeSystemAudio ? " and screen-recording" : "") +
                 " access — audio is transcribed on-device and never leaves your Mac.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
            Button {
                Task { await rec.start(env: env, presetTitle: presetTitle) }
            } label: {
                Label("Start recording", systemImage: "record.circle.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(Theme.danger).controlSize(.large)
        }
        .frame(maxWidth: 460, alignment: .leading)
        .onAppear {
            // Pick up the CURRENT default (it may have changed in Settings since launch) + heal a stale id
            // (e.g. a custom template that was removed) — audit LOW.
            if env.noteTemplates.template(id: rec.selectedTemplateID) == nil
                || rec.phase == .idle {
                rec.selectedTemplateID = env.noteTemplates.defaultID
            }
        }
    }

    /// Pick the note TEMPLATE for this recording (Granola Phase C) — shapes how the AI structures the
    /// live notes. Sits in the start form so it's chosen before recording begins.
    @ViewBuilder private func templatePicker(_ rec: RecordingModel) -> some View {
        @Bindable var rec = rec
        let current = env.noteTemplates.template(id: rec.selectedTemplateID) ?? .general
        HStack(spacing: 8) {
            Text("AI notes template").font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Menu {
                ForEach(env.noteTemplates.all) { t in
                    Button { rec.selectedTemplateID = t.id } label: { Label(t.name, systemImage: t.icon) }
                }
            } label: {
                Label(current.name, systemImage: current.icon).font(.system(size: 12))
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
    }

    @ViewBuilder private func liveControls(_ rec: RecordingModel) -> some View {
        @Bindable var rec = rec
        VStack(alignment: .leading, spacing: 12) {
            // Top bar: live state + Stop, so the body below is pure content.
            HStack(spacing: 10) {
                RecordingDot()
                Text(rec.elapsedString).font(.system(size: 22, weight: .semibold)).monospacedDigit()
                Spacer()
                MicStateBadge(state: rec.micState)
                    .animation(Theme.smooth, value: rec.micState)
                SystemAudioBadge(state: rec.systemAudioState, includeSystemAudio: rec.includeSystemAudio)
                    .animation(Theme.smooth, value: rec.systemAudioState)
                LevelMeter(level: rec.level)
                Button {
                    Task { await rec.stop(env: env); dismiss() }
                } label: {
                    Label("Stop & transcribe", systemImage: "stop.circle.fill")
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
            }
            // Two-column canvas: your notes + the live speaker-labeled transcript on the left,
            // the AI catch-up assistant on the right (the "I dozed off" flow stays a co-hero).
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    AINotesCard(model: rec.notes)   // Granola-style notes that write themselves
                    NotesCanvas(text: $rec.liveNotes)
                    // Prefer the extension's Google Meet captions (real names, accurate) when they're
                    // relaying; otherwise fall back to the on-device You/Them audio transcript (T2 slice 2).
                    if rec.hasLiveCaptions {
                        LiveCaptionPeek(turns: rec.liveCaptions)
                    } else {
                        LiveTranscriptPeek(lines: rec.live?.lines ?? [])
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                LiveAssistantPanel(model: rec.assistant)
                    .frame(width: 340)
                    .frame(maxHeight: .infinity)
            }
            .frame(minHeight: 440, alignment: .top)
        }
    }
}

/// "Notes that write themselves" (Granola-style): the AI's rolling bullet notes for the call so far,
/// auto-updating on the warm local model. Calm violet card; a subtle "updating…" while a pass runs.
private struct AINotesCard: View {
    let model: LiveNotesModel?

    var body: some View {
        if let model {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text("AI notes").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent)
                    Spacer(minLength: 0)
                    if model.isWriting {
                        Text("updating…").font(.system(size: 10)).foregroundStyle(.tertiary)
                            .transition(.opacity)
                    }
                }
                if model.notes.isEmpty {
                    Text("Notes will write themselves as the conversation develops…")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 2)
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(model.notes.enumerated()), id: \.offset) { _, note in
                            if note.isHeader {
                                Text(note.text.uppercased())
                                    .font(.system(size: 10, weight: .semibold)).tracking(0.5)
                                    .foregroundStyle(Theme.accent)
                                    .padding(.top, 4)
                            } else {
                                HStack(alignment: .top, spacing: 7) {
                                    Circle().fill(Theme.accent.opacity(0.6)).frame(width: 4, height: 4)
                                        .padding(.top, 6)
                                    Text(note.text).font(.system(size: 13)).foregroundStyle(.primary).lineSpacing(1.5)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    .transition(.opacity)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.accent.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.accent.opacity(0.15)))
            .animation(Theme.smooth, value: model.notes)
            .animation(Theme.smooth, value: model.isWriting)
        }
    }
}

/// Your live notes as a proper canvas. The AI's auto-notes live in `AINotesCard` above; this stays a
/// generous, calm editor for what YOU jot during the call.
private struct NotesCanvas: View {
    @Binding var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your notes").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            TextField("Jot key points as you go — names, decisions, follow-ups…", text: $text, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 14)).lineSpacing(3)
                .lineLimit(6...)
                .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.cardFill))
                .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.hairline))
        }
    }
}

/// Glanceable mic-gate state: are we recording YOU right now, paused on silence, or muted (in Meet)?
/// Hidden when the gate is off (mic always recording, so no signal needed).
private struct MicStateBadge: View {
    let state: MicState
    var body: some View {
        if let d = descriptor {
            HStack(spacing: 4) {
                Image(systemName: d.icon).font(.system(size: 10, weight: .semibold))
                Text(d.label).font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(d.color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(d.color.opacity(0.14)))
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }
    private var descriptor: (icon: String, label: String, color: Color)? {
        switch state {
        case .speaking: (icon: "mic.fill", label: "Recording you", color: Theme.accent)
        case .silent:   (icon: "mic", label: "Paused · silence", color: Theme.textSecondary)
        case .muted:    (icon: "mic.slash.fill", label: "Muted", color: Theme.warning)
        case .off:      nil
        }
    }
}

/// Separate health signal for the other side of the call. The mic badge can be healthy while
/// ScreenCaptureKit is missing Google Meet/system audio, so this must be visible on its own.
private struct SystemAudioBadge: View {
    let state: SystemAudioCaptureState
    let includeSystemAudio: Bool

    var body: some View {
        if let d = descriptor {
            HStack(spacing: 4) {
                Image(systemName: d.icon).font(.system(size: 10, weight: .semibold))
                Text(d.label).font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(d.color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(d.color.opacity(0.14)))
            .help(d.help)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }

    private var descriptor: (icon: String, label: String, color: Color, help: String)? {
        guard includeSystemAudio else { return nil }
        switch state {
        case .starting:
            return ("speaker.wave.2", "Call audio...", Theme.textSecondary,
                    "Starting system-audio capture.")
        case .capturing:
            return ("speaker.wave.2", "Call audio ready", Theme.textSecondary,
                    "System-audio capture started; waiting for meeting audio.")
        case .receiving:
            return ("speaker.wave.2.fill", "Call audio", Theme.success,
                    "Recording the other participants.")
        case .noSamples:
            return ("exclamationmark.triangle.fill", "No call audio", Theme.warning,
                    "No Google Meet or system audio has been received yet.")
        case .failed(let reason):
            return ("exclamationmark.triangle.fill", "Call audio off", Theme.warning, reason)
        case .off:
            return nil
        }
    }
}

/// The prominent Record entry point pinned to the top of the sidebar. Idle → a red "Record
/// meeting" button; live → a compact pulsing "Recording…" chip that reopens the panel.
struct RecordButton: View {
    @Environment(AppEnvironment.self) private var env
    var body: some View {
        let rec = env.recording
        Button { env.recordSheetShown = true } label: {
            HStack(spacing: 7) {
                switch rec.phase {
                case .idle:
                    Image(systemName: "record.circle.fill")
                    Text("Record meeting").fontWeight(.medium)
                case .recording:
                    RecordingDot()
                    Text(rec.elapsedString).monospacedDigit().fontWeight(.medium)
                    Spacer(minLength: 0)
                    Text("Recording").font(.caption).foregroundStyle(.secondary)
                case .processing:
                    ProgressView().controlSize(.small)
                    Text("Transcribing…").fontWeight(.medium)
                }
            }
            .font(.system(size: 13))
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .fill(rec.phase == .idle ? Theme.dangerSoft : Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).strokeBorder(
                rec.phase == .idle ? Theme.danger.opacity(0.35) : Theme.hairline))
            .foregroundStyle(rec.phase == .idle ? Theme.danger : Theme.textPrimary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Record a live meeting (⌘R)")
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.bar)
    }
}

/// A slim always-visible bar shown while a recording runs (or transcribes) so the founder never
/// loses track of it after dismissing the panel. Click to reopen; Stop ends it in place.
struct RecordingBar: View {
    @Environment(AppEnvironment.self) private var env
    var body: some View {
        let rec = env.recording
        HStack(spacing: 10) {
            if rec.phase == .processing {
                ProgressView().controlSize(.small)
                Text("Transcribing your recording…").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                RecordingDot()
                Text("Recording").font(.system(size: 12, weight: .semibold))
                Text(rec.elapsedString).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                SystemAudioBadge(state: rec.systemAudioState, includeSystemAudio: rec.includeSystemAudio)
                LevelMeter(level: rec.level)
                Spacer(minLength: 8)
                Button { Task { await env.recording.stop(env: env) } } label: {
                    Label("Stop", systemImage: "stop.fill").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent).tint(Theme.danger).controlSize(.small)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(Theme.hairline))
        .contentShape(Capsule())
        .onTapGesture { if rec.phase == .recording { env.recordSheetShown = true } }
        .padding(.top, 8)
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }
}

/// Pulsing red dot for the live state.
private struct RecordingDot: View {
    @State private var on = false
    var body: some View {
        Circle().fill(Theme.danger).frame(width: 10, height: 10)
            .opacity(on ? 1 : 0.35)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

/// A small horizontal level meter driven by the mic RMS.
private struct LevelMeter: View {
    let level: Float
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<12, id: \.self) { i in
                let threshold = Float(i) / 12
                RoundedRectangle(cornerRadius: 1)
                    .fill(level > threshold ? Theme.accent : Color.secondary.opacity(0.2))
                    .frame(width: 3, height: 6 + CGFloat(i) * 1.2)
            }
        }
        .animation(.linear(duration: 0.1), value: level)
    }
}
