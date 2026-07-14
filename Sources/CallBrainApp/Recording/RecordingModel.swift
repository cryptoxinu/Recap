import SwiftUI
import os
import CallBrainCore
import CallBrainAppCore

/// Orchestrates a live recording: capture audio → on stop, name the file for the meeting and
/// hand it to the SAME import pipeline that transcribes + ingests + summarizes. Live notes the
/// founder types are saved onto the resulting meeting once it's ingested.
@MainActor
@Observable
final class RecordingModel {
    enum Phase: Equatable { case idle, recording, processing }

    private(set) var phase: Phase = .idle
    private(set) var elapsed: TimeInterval = 0
    var title = ""
    var liveNotes = ""
    private(set) var live: LiveTranscript?
    private(set) var assistant: LiveAssistantModel?
    private(set) var notes: LiveNotesModel?
    private(set) var errorText: String?
    /// Set when a recording couldn't start because a macOS recording permission is denied — drives a
    /// one-tap "Open System Settings" button so the founder can re-grant it without hunting (Phase 6).
    private(set) var permissionIssue: PrivacySettings.Kind?
    /// Live Google Meet captions (real speaker names) relayed by the extension during THIS recording,
    /// polled on the ticker so the panel can show accurate named turns instead of the You/Them audio
    /// guess (T2 slice 2). Empty when no extension/captions — the panel then falls back to the audio peek.
    private(set) var liveCaptions: [CaptionTurn] = []
    var hasLiveCaptions: Bool { !liveCaptions.isEmpty }
    /// The note TEMPLATE for this recording (Granola Phase C) — shapes the AI-notes structure. Chosen in
    /// the idle form; defaults to the user's default template.
    var selectedTemplateID: String = NoteTemplateLibrary.load().defaultID

    let capture = AudioCapture()
    private var ticker: Task<Void, Never>?
    /// Guards the async gap between the `phase == .idle` check and `phase = .recording`: `capture.start()`
    /// is awaited, so without this a rapid second `start()` would pass the phase guard and spin up a
    /// duplicate capture/assistant/warmUp (audit MED).
    private var starting = false
    /// The calendar event a STARTED recording is linked to — committed only inside `start()`, so a
    /// panel opened-then-dismissed (or a capture failure) can't leave a stale link on the shared
    /// model for the next manual recording to inherit (P3 audit HIGH).
    private(set) var linkedEventID: String?
    /// The INTENDED link, set by the calendar / auto-record flows before Start. Cleared on dismiss.
    var pendingEventID: String?
    /// The wall-clock instant this recording actually began — captured once capture starts, carried
    /// through the durable hand-off so the eventual meeting's `start_time` is the real call time (not
    /// midnight-of-day). nil until a recording is running.
    private(set) var startedAt: Date?

    var level: Float { capture.level }
    var micState: MicState { capture.micState }
    var systemAudioState: SystemAudioCaptureState { capture.systemAudioState }
    /// Bindable passthrough so the UI toggle drives the capture without reaching two levels deep.
    var includeSystemAudio: Bool {
        get { capture.includeSystemAudio }
        set { capture.includeSystemAudio = newValue }
    }
    var micGateEnabled: Bool {
        get { capture.micGateEnabled }
        set { capture.micGateEnabled = newValue }
    }

    func setMeetMuted(_ muted: Bool) {
        capture.setMeetMuted(muted)
    }

    /// Begin a pre-linked recording automatically (opt-in auto-record). Silently no-ops if one is
    /// already running; a mic-denied failure surfaces via `errorText` if the panel is opened.
    func startAuto(env: AppEnvironment, title: String, eventID: String) async {
        guard phase == .idle else { return }
        pendingEventID = eventID
        await start(env: env, presetTitle: title)
    }

    /// Clear the calendar preset when the panel is dismissed without recording (P3 audit HIGH —
    /// no stale link/title bleeding into the next manual recording). Never touches a live one — and
    /// never one whose `start()` is mid-flight (phase is still `.idle` across the async `capture.start()`
    /// gap, so without the `!starting` guard, closing the window then would wipe the title/preset that
    /// start is about to use — window audit MED).
    func clearPresetIfIdle() {
        guard phase == .idle, !starting else { return }
        title = ""; pendingEventID = nil
    }

    func start(env: AppEnvironment, presetTitle: String? = nil) async {
        guard phase == .idle, !starting else { return }
        starting = true
        defer { starting = false }
        errorText = nil
        permissionIssue = nil
        if let presetTitle, title.isEmpty { title = presetTitle }
        // Manual "Record meeting" with no pre-selected event: auto-detect the scheduled calendar call
        // happening RIGHT NOW and pre-link + auto-title from it — so a recording of a scheduled call is
        // linked and named without the founder doing anything (the calendar-UI Record path already sets
        // pendingEventID, so this only fills the gap for the generic Record button).
        if pendingEventID == nil, let ev = env.calendarHub.eventHappeningNow() {
            pendingEventID = ev.id
            if title.isEmpty { title = ev.title }
        }
        // Commit the pending calendar link ONLY now that a recording is actually beginning.
        linkedEventID = pendingEventID
        // Claim + clear the Meet-caption buffer BEFORE the awaited capture start (audit HIGH/MED): the
        // lease stops a concurrent extension `/import` from wiping our captions, and taking it before the
        // suspension means captions relayed during capture startup land in THIS recording's window.
        env.meetSession.beginRecording()
        // Stamp the real start instant NOW — right before capture begins — not after the model/assistant
        // setup below, so slow warm-up can't push the persisted start time forward and weaken calendar
        // proximity matching (audit LOW). Kept only if capture actually starts.
        let began = Date()
        do {
            // Auto-start the local AI if it was left off, so AI notes / catch-up assistant / summaries never
            // silently fail on a recording (founder: kick on by itself in case I left it off). Fire-and-forget
            // — audio capture doesn't wait on it; the assistant's retry loop connects once it's up (~2s).
            Task.detached { await SystemStatus.ensureRunning() }
            try await capture.start()
            // Capturing the OTHER participants ("Call audio") needs Screen Recording. If it isn't granted yet,
            // keep recording your mic but surface a ONE-TAP fix — the on-device live transcript still works for
            // what your mic hears, and enabling Screen Recording captures the whole call next time. (The native
            // "Allow" dialog is popped from SystemAudioCapture; this drives the in-window banner + Settings jump.)
            if !PrivacySettings.screenRecordingAuthorized() {
                permissionIssue = .screenRecording
                errorText = "Recap can hear you, but not the other participants yet. Turn on Screen Recording for Recap (button below), then start the recording again to capture the whole call."
            }
            // Fetch the high-accuracy final-pass model in the background now, so it's likely cached by
            // the time the call ends — the live path uses the small cached model and never waits on it.
            env.ensureFinalTranscriptionModel()
            env.ensureLiveTranscriptionModel()
            let lt = LiveTranscript(source: capture.live, transcriber: env.liveTranscriber)
            lt.start()
            self.live = lt
            let engine = env.ask
            // The transcript both the catch-up assistant AND the auto-notes read. PREFER the extension's
            // Google Meet captions (real participant names) whenever they're flowing, and fall back to the
            // on-device You/Them audio transcript only when there are no captions (CC off, extension not
            // paired, or a non-Meet call). This is what stops the AI notes from writing "Them has a PR…" —
            // the display panel already prefers named captions (RecordView), so now the notes/assistant match.
            let session = env.meetSession
            let liveTranscriptText: @MainActor () -> String = { [weak lt] in
                // Skip building the caption string when there are no captions (cheap short-circuit), then
                // let the pure, tested helper decide which source wins.
                preferredLiveTranscript(
                    captions: session.isEmpty ? "" : session.transcript(),
                    audio: lt?.currentText() ?? ""
                )
            }
            let assistant = LiveAssistantModel(ask: engine, transcript: liveTranscriptText)
            assistant.warmUp()   // prime the local fast model so the first in-call answer is instant
            assistant.startAutoSuggestions()
            self.assistant = assistant
            // "Notes that write themselves" (Granola-style) — same warm local lane, growth-gated so it
            // doesn't burn the model on unchanged transcript. The chosen template shapes the structure.
            let template = env.noteTemplates.template(id: selectedTemplateID) ?? .general
            let notes = LiveNotesModel(source: engine, transcript: liveTranscriptText,
                                       instructions: template.instructions)
            notes.start()
            self.notes = notes
            phase = .recording
            startedAt = began   // real call start (stamped pre-capture) — threaded to meetings.start_time
            elapsed = 0
            liveCaptions = []
            ticker = Task { [weak self, session = env.meetSession] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, self.phase == .recording else { return }
                    self.elapsed += 1
                    // Reflect the extension's relayed captions into the panel (recent tail only, for a
                    // stable bounded view). No-op when the extension isn't feeding this call.
                    self.liveCaptions = Array(session.turns().suffix(80))
                }
            }
        } catch {
            env.meetSession.endRecording()   // capture failed → release the caption lease we took above
            errorText = error.localizedDescription
            // A denied-mic start is recoverable in one tap — flag it so the UI can offer the Settings jump.
            if case AudioCapture.CaptureError.micDenied = error { permissionIssue = .microphone }
            phase = .idle
            linkedEventID = nil   // capture failed → don't strand a link for the next recording
        }
    }

    /// Stop, name the recording, and enqueue it for transcription. Returns the meeting's
    /// import URL (so callers can track it); live notes attach after ingest.
    @discardableResult
    func stop(env: AppEnvironment) async -> URL? {
        guard phase == .recording else { return nil }
        live?.stop()
        // Drain the living-notes writer (cancel + await its in-flight summarize) BEFORE the assistant
        // releases the shared Ollama lane, so no notes pass can re-pin the model after release.
        await notes?.drain()
        assistant?.stop()
        // Release the warm live transcription model now that the call is over — nothing should stay
        // resident draining battery/memory when we're not recording (founder). The final pass owns its
        // own model. (The assistant's Ollama fast lane is unloaded in LiveAssistantModel.stop().)
        env.releaseLiveTranscriptionModel()
        ticker?.cancel(); ticker = nil
        phase = .processing
        // Harvest this recording's Meet captions atomically (snapshot + clear + release the lease under one
        // lock) NOW, before capture.stop() — so it runs on EVERY stop path and no concurrent /live append
        // is lost or leaks into the next recording (audit HIGH). Empty when the extension relayed nothing.
        let harvest = env.meetSession.endRecording()
        // Only trust captions as the SAVED transcript when the recording ACTUALLY captured the other side's
        // audio (system-audio samples really arrived — not merely that the toggle was on, since
        // ScreenCaptureKit can fail/yield nothing). Guards the "mic-only recording while a background Meet
        // tab is captioning" case from stealing an unrelated call's captions (T2 audit MED). Read BEFORE
        // stop() clears it. A concurrent SECOND live Meet call can still contaminate — real fix is T4.
        let capturedCallAudio = capture.didCaptureCallAudio
        guard let raw = await capture.stop() else { phase = .idle; return nil }
        // A mid-recording write failure still yields a (partial) WAV — process it, but tell the
        // founder it may be incomplete rather than pretending it's whole (P2b audit MED).
        let warnings = [
            capture.lastRecordingIncomplete
                ? "Saved, but a disk write failed — the recording may be missing some audio." : nil,
            capture.lastSystemAudioWarning,
        ].compactMap { $0 }
        errorText = warnings.isEmpty ? nil : warnings.joined(separator: " ")

        // Rename to a titled file so the meeting reads well (the pipeline uses the filename).
        // Disambiguate a same-title/same-minute collision with a counter so the title survives
        // instead of falling back to the raw UUID name (P1 audit LOW).
        // A no-title recording gets a FINDABLE default with the real clock time (not a bare "Recording"
        // that's indistinguishable across calls) — so the founder can spot it in Meetings immediately.
        let name = (title.trimmingCharacters(in: .whitespaces).isEmpty ? Self.defaultTitle() : title)
        let stamp = Self.fileStamp()
        let dir = raw.deletingLastPathComponent(), base = "\(Self.safe(name)) — \(stamp)"
        var dest = dir.appendingPathComponent("\(base).wav")
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\(base) (\(n)).wav"); n += 1
        }
        try? FileManager.default.moveItem(at: raw, to: dest)
        let url = FileManager.default.fileExists(atPath: dest.path) ? dest : raw

        // Move the remote-only (system) audio sibling alongside the renamed WAV so the transcription pass
        // can find it by convention for dual-channel group attribution (T3). Only keep it when this was a
        // real call recording (system audio actually arrived); a mic-only recording's silent sibling would
        // just make the pass diarize silence, so drop it and let the mono path run.
        let rawSystem = RecordingSidecars.systemAudioURL(forRecording: raw)
        if FileManager.default.fileExists(atPath: rawSystem.path) {
            let finalSystem = RecordingSidecars.systemAudioURL(forRecording: url)
            if capturedCallAudio, finalSystem != rawSystem {
                // Clear any STALE orphan sibling at this stem first (a prior recording whose visible WAV was
                // deleted could leave one behind; the visible-WAV collision counter doesn't see hidden
                // siblings) — else the move would silently fail and the OLD call's remote timeline would get
                // attached to THIS recording (audit HIGH). If the move still fails, drop dual-channel entirely.
                try? FileManager.default.removeItem(at: finalSystem)
                do { try FileManager.default.moveItem(at: rawSystem, to: finalSystem) }
                catch {
                    try? FileManager.default.removeItem(at: rawSystem)
                    Logger(subsystem: "com.callbrain", category: "recording")
                        .error("failed to place system-audio sidecar: \(error.localizedDescription, privacy: .public)")
                }
            } else if !capturedCallAudio {
                try? FileManager.default.removeItem(at: rawSystem)   // no real remote audio → no dual channel
            }
        }

        // If the Chrome extension relayed Google Meet captions during this recording, persist them as a
        // sidecar next to the WAV (harvested atomically above). The import pipeline PREFERS these (accurate
        // text + real speaker names) over on-device WhisperKit; the WAV is kept as the audio backup and
        // drives the same notes/calendar-link plumbing (payload == its path). We write the sidecar ONLY when
        // the captions are complete AND this was a real call recording:
        //  • harvest.truncated → the live buffer's cap evicted early turns, so a caption sidecar would be
        //    head-truncated — skip it and let WhisperKit transcribe the FULL WAV instead (no silent loss).
        //  • !capturedCallAudio → mic-only recording; captions likely belong to some other Meet tab — skip.
        if !harvest.turns.isEmpty, !harvest.truncated, capturedCallAudio {
            let captions = MeetCaptionTranscript(title: name, date: TimeCode.ymd(Date()), turns: harvest.turns)
            if captions.hasContent {
                do { try captions.write(to: MeetCaptionTranscript.sidecarURL(forRecording: url)) }
                catch {
                    Logger(subsystem: "com.callbrain", category: "recording")
                        .error("failed to write Meet-caption sidecar: \(error.localizedDescription, privacy: .public)")
                }
            }
        } else if harvest.truncated {
            Logger(subsystem: "com.callbrain", category: "recording")
                .notice("Meet captions exceeded the live buffer; using WhisperKit over the full recording instead.")
        }

        let queued = await env.importCoordinator.enqueueFilesReturningQueued([url])

        // Persist the note + calendar-link + start-time intent DURABLY, keyed by the file path (== the
        // import job's payload). The pipeline can take minutes (first-run model download) or finish after
        // an app relaunch; `reconcileRecordingLinks()` resolves this row whenever the job lands a meeting —
        // replacing the old in-memory 60s poll that lost links on either (P1 audit HIGH). We ALWAYS write
        // the row for a recording now (not only when there are notes/a link): even a bare recording carries
        // a real `startedAt` that must reach `meetings.start_time` for correct time + calendar auto-linking.
        if let queuedURL = queued.first {
            let notes = liveNotes, eventID = linkedEventID, path = queuedURL.path, began = startedAt
            let store = env.store
            // This durable row is the ONLY carrier of a bare recording's start time (+ any notes/link),
            // so a failed write can't be swallowed silently — surface it so the founder knows the time/
            // notes may not attach, instead of a call quietly landing at midnight-of-day (audit MED).
            let saved = await Task.detached {
                (try? store.savePendingRecordingLink(filePath: path, eventID: eventID, notes: notes,
                                                     startedAt: began)) != nil
            }.value
            if !saved {
                let warn = "Couldn't save this recording's start time" +
                    ((!notes.isEmpty || eventID != nil) ? " / notes / calendar link" : "") +
                    " — they may not attach to the transcript."
                errorText = errorText.map { "\($0) \(warn)" } ?? warn
            }
            // Opportunistic first pass in case ingest is already done (a short paste-like clip).
            await env.reconcileRecordingLinks()
        }
        // Reset for the next recording (linkedEventID + pendingEventID + startedAt too — else a later
        // manual recording would inherit a stale event link / start time, P1 audit MED / P3 audit HIGH).
        title = ""; liveNotes = ""; elapsed = 0; linkedEventID = nil; pendingEventID = nil; startedAt = nil
        live = nil; assistant = nil; notes = nil; liveCaptions = []
        phase = .idle
        return queued.first
    }

    var elapsedString: String {
        let s = Int(elapsed); return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func fileStamp() -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HHmm"; df.locale = Locale(identifier: "en_US_POSIX")
        return df.string(from: Date())
    }
    /// Findable default title for an untitled recording: "Recording · Jul 11, 2:05 PM".
    static func defaultTitle(_ now: Date = Date()) -> String {
        let df = DateFormatter(); df.dateFormat = "MMM d, h:mm a"; df.locale = Locale(identifier: "en_US_POSIX")
        return "Recording · \(df.string(from: now))"
    }
    static func safe(_ s: String) -> String {
        s.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
    }
}
