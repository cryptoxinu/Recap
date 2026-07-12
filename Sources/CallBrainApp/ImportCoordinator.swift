import SwiftUI
import os
import CallBrainCore
import CallBrainAppCore

/// Drives the durable import queue (Phase 2). Files and pasted text become persisted `ImportJob`s —
/// including their payload (file path / pasted text) — and are processed **serially** (so Ollama/claude
/// aren't hammered by a multi-file drop). State + payload are written through to the store, so the queue
/// survives relaunch: an interrupted job RESUMES (re-running is idempotent via content-hash dedupe), and
/// a 150-file backlog is drained from the store, not a display-limited list.
@MainActor
@Observable
final class ImportCoordinator {
    private let env: AppEnvironment
    private(set) var jobs: [ImportJob] = []      // newest-100, for display
    private(set) var processing = false
    /// Surfaced to the UI when enqueue/persist fails — never silently drop an import (Codex audit).
    var lastError: String?

    init(env: AppEnvironment) {
        self.env = env
        Task { [weak self] in
            await self?.reload()
            await self?.requeueInterrupted()          // jobs left 'running' by a crash → 'queued' so drain resumes
            await self?.requeueTranscriptionCrashes() // heal past WhisperKit-crash failures on the fixed build
            self?.startDraining()                     // pick up anything still queued from a previous session
            await self?.env.reconcileRecordingLinks() // resolve recordings ingested while closed
        }
    }

    /// Refresh the display list — the Store read runs OFF the main thread (audit: no main-thread SQLite).
    /// Live transcription progress ("Transcribing… 42%") lives only in the in-memory `jobs` array (it's not
    /// persisted per tick), so a concurrent reload would clobber it with the store row's nil message. Preserve
    /// the in-memory progress label for still-`.running` jobs whose fresh store row has no message, so the
    /// spinner text stays stable instead of flashing empty during a multi-file drop.
    func reload() async {
        let store = env.store
        let previous = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0) })
        var fresh = await Task.detached { (try? store.importJobs()) ?? [] }.value
        for i in fresh.indices where fresh[i].state == .running && (fresh[i].message?.isEmpty ?? true) {
            if let old = previous[fresh[i].id], old.state == .running, let msg = old.message, !msg.isEmpty {
                fresh[i].message = msg
            }
        }
        jobs = fresh
    }

    /// True if any of these files has an extension Recap can read.
    /// Audio/video files we transcribe on-device (Phase 3) rather than parse as text.
    nonisolated static let mediaExtensions: Set<String> = ["mp4", "mov", "m4a", "wav", "webm", "mp3", "aac", "caf", "m4v"]
    static func isMedia(_ url: URL) -> Bool { mediaExtensions.contains(url.pathExtension.lowercased()) }

    static func importable(_ urls: [URL]) -> [URL] {
        urls.filter {
            let ext = $0.pathExtension.lowercased()
            return IngestEngine.readableExtensions.contains(ext) || mediaExtensions.contains(ext)
        }
    }

    @discardableResult
    func enqueueFiles(_ urls: [URL]) async -> Int { await enqueueFilesReturningQueued(urls).count }

    /// Like `enqueueFiles` but returns exactly the URLs that were durably queued, so a caller can record
    /// only what actually succeeded (Drive sync marks only enqueued files as synced — never a file whose
    /// job failed to persist, which would silently drop it forever). ALL the row writes happen in a single
    /// OFF-MAIN batch, so dropping a 500-file folder never freezes the UI (audit HIGH).
    @discardableResult
    func enqueueFilesReturningQueued(_ urls: [URL]) async -> [URL] {
        let files = Self.importable(urls)
        guard !files.isEmpty else { return [] }
        let store = env.store
        let pairs = files.map { url in
            (url, ImportJob(id: newID(), sourceName: url.lastPathComponent,
                            createdAt: now(), payloadKind: .file, payload: url.path))
        }
        let queued: [URL] = await Task.detached {
            var ok: [URL] = []
            for (url, job) in pairs { if (try? store.upsertImportJob(job)) != nil { ok.append(url) } }
            return ok
        }.value
        if queued.count < files.count { lastError = "Some files couldn't be queued — try again." }
        if !queued.isEmpty { await reload(); startDraining() }
        return queued
    }

    /// Archive migration (Phase 7): recursively scan a folder for importable transcripts + recordings and
    /// enqueue them all into this same durable, serially-paced queue. The folder walk (up to 5000 files) AND
    /// the row writes run OFF the main thread (audit HIGH). Returns how many were enqueued.
    @discardableResult
    func enqueueFolder(_ folder: URL) async -> Int {
        let scanned = await Task.detached { Self.scanFolder(folder) }.value
        return await enqueueFiles(scanned)
    }

    /// All importable files under a directory (recursive), skipping hidden/package contents. `nonisolated`
    /// so the (potentially large) folder walk can run OFF the main thread.
    nonisolated static func scanFolder(_ folder: URL, max: Int = 5000) -> [URL] {
        FolderScanner.importableFiles(in: folder,
                                      recognized: IngestEngine.readableExtensions.union(mediaExtensions), max: max)
    }

    /// Returns false if the job couldn't be persisted (so the caller can keep the user's text).
    @discardableResult
    func enqueuePaste(_ text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let job = ImportJob(id: newID(), sourceName: "Pasted text",
                            createdAt: now(), payloadKind: .paste, payload: trimmed)
        guard await persist(job) else { return false }
        startDraining()
        return true
    }

    func clearFinished() async {
        let store = env.store
        let ok = await Task.detached { (try? store.clearFinishedImportJobs()) != nil }.value
        if ok { await reload() } else { lastError = "Couldn't clear finished imports." }
    }

    func remove(_ job: ImportJob) async {
        let store = env.store, id = job.id
        await AppEnvironment.loggedWrite("deleteImportJob") { try store.deleteImportJob(id: id) }
        await reload()
    }

    func confirmReviewed(_ job: ImportJob) async {
        var j = job; j.state = .done; j.message = nil; _ = await persist(j)
    }

    /// One-click retry of a FAILED job (Task 8.4): payload (file path / pasted text) is already
    /// persisted, so re-queue + drain. Idempotent — content-hash dedupe makes a double-retry safe.
    func retry(_ job: ImportJob) async {
        guard job.state == .failed else { return }
        var j = job; j.state = .queued; j.message = nil; j.meetingID = nil; j.chunkCount = 0
        guard await persist(j) else { return }
        startDraining()
    }

    // MARK: - processing

    /// The lost-wakeup-safe serial-drain state machine — extracted + TESTED in AppCore (E2).
    @ObservationIgnored private var drainGate = SerialDrainGate()

    private func startDraining() {
        guard drainGate.requestDrain() else { return }    // already draining → flagged to loop again
        processing = true
        // Defeat App Nap + idle sleep while importing/transcribing so jobs finish even if the user steps
        // away or closes the window (Phase 6). The token is released when the queue drains.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Importing calls")
        Task { [weak self] in
            guard let self else { return }
            // The only suspension is inside drain(); a mid-drain enqueue flags the gate → we loop.
            repeat { await self.drain() } while self.drainGate.shouldLoop()
            self.drainGate.finish()
            self.processing = false
            ProcessInfo.processInfo.endActivity(activity)
        }
    }

    private func drain() async {
        // Pull the full pending set from the store each pass (not the display list) so a large backlog
        // fully drains and newly-enqueued jobs are seen. The read runs off-main (audit: no main-thread SQLite).
        let store = env.store
        while let job = await Task.detached(operation: {
            (try? store.pendingImportJobs())?.first(where: { $0.state == .queued })
        }).value {
            // If we can't even mark the job running (DB write failing), STOP — otherwise the still-`.queued`
            // row would be re-read and re-imported every iteration in a tight loop (audit MED: re-run).
            if await run(job) == false { break }
        }
        env.refreshReminders()   // new imports can add tasks → keep the reminder count fresh
    }

    /// Returns false ONLY when the initial `.running` mark couldn't be persisted — the job is still `.queued`
    /// in the DB, so the drain must stop rather than re-read + re-import it forever (audit MED).
    @discardableResult
    private func run(_ job: ImportJob) async -> Bool {
        var j = job; j.state = .running
        guard await persist(j) else { return false }

        do {
            // Media file → on-device transcription path (decode → WhisperKit → FluidAudio → ingest).
            if job.payloadKind == .file, let path = job.payload, Self.isMedia(URL(fileURLWithPath: path)) {
                try await runTranscription(job: &j, path: path)
                _ = await persist(j)
                // A live recording's WAV lands here — resolve its durable note/calendar link + real
                // start time now that the meeting exists (no-op for ordinary imports), then re-run the
                // calendar linker so a recording of a scheduled call links to its event immediately on
                // ingest rather than only on the next calendar refresh (P2e).
                if j.meetingID != nil {
                    await env.reconcileRecordingLinks()
                    env.calendarHub.runLinker()
                }
                // The remote-only (T3) sidecar has served its purpose (consumed by dual transcription, or
                // bypassed by captions) once transcription SUCCEEDED — remove it so hidden aux files don't
                // accumulate. Reached only on success; a thrown transcription keeps it for the retry.
                try? FileManager.default.removeItem(
                    at: RecordingSidecars.systemAudioURL(forRecording: URL(fileURLWithPath: path)))
                return true
            }

            let (outcome, resolved): (IngestEngine.Outcome, AIImporter.Resolved)
            switch (job.payloadKind, job.payload) {
            case (.file, .some(let path)):
                let url = URL(fileURLWithPath: path)
                guard FileManager.default.fileExists(atPath: path) else {
                    throw ImportRunError.missingFile(url.lastPathComponent)
                }
                (outcome, resolved) = try await env.ingest.ingestFile(at: url, importer: env.importer)
            case (.paste, .some(let text)):
                (outcome, resolved) = try await env.ingest.ingestRaw(text, importer: env.importer)
            default:
                throw ImportRunError.noPayload
            }
            j.format = resolved.format.rawValue
            j.usedAI = resolved.usedAI
            j.meetingID = outcome.meetingID
            j.title = resolved.transcript.title
            j.chunkCount = outcome.chunkCount
            if outcome.deduped {
                j.state = .done
                j.message = "Already imported — this matches a call already in your library."
            } else if resolved.usedAI {
                j.state = .needsReview
                j.message = "AI structured this — open it to confirm speakers/turns look right."
            } else {
                j.state = .done
                j.message = nil
            }
            if !outcome.deduped {
                env.generateTitleIntelligence(for: outcome.meetingID)   // proper AI title + one-liner
                env.summarizeInBackground(outcome.meetingID)            // queue the full Summary-tab pass
                env.classifyInBackground(outcome.meetingID)             // Ambient / Further Health / Other tag
                env.completeMatchingTasks(for: outcome.meetingID)       // auto-complete earlier tasks this call says are done
                env.corpus.scheduleSync()                              // export the new call (re-exports when the summary lands)
                if outcome.embedded == 0, outcome.chunkCount > 0 {
                    // Imported while Ollama was down — try to settle the IOUs now (gate MED:
                    // drain must not be launch-only). No-op if the embedder is still out.
                    env.drainPendingEmbeddings()
                }
            }
            _ = await persist(j)
        } catch {
            j.state = .failed
            j.message = Self.friendly(error)
            _ = await persist(j)
        }
        return true
    }

    /// Transcribe a media file on-device, then ingest the result like any other meeting.
    private func runTranscription(job j: inout ImportJob, path: String) async throws {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            throw ImportRunError.missingFile(url.lastPathComponent)
        }
        // Prefer relayed Google Meet captions (accurate text + real speaker names) over on-device
        // WhisperKit whenever this recording carried them (T2). A missing/empty sidecar → fall through
        // to WhisperKit exactly as before, so non-Meet and extension-less recordings are unaffected.
        let sidecar = MeetCaptionTranscript.sidecarURL(forRecording: url)
        if let captions = MeetCaptionTranscript.read(from: sidecar) {
            do {
                try await ingestCaptions(job: &j, captions: captions, audioURL: url)
                return
            } catch {
                // Captions are best-effort: a valid-but-unusable sidecar must NOT pin this recording to a
                // failing caption ingest on every retry (audit MED). Quarantine it and fall through to the
                // WhisperKit path in this same pass, so the recording still gets a transcript.
                let failed = sidecar.appendingPathExtension("failed")
                try? FileManager.default.removeItem(at: failed)
                try? FileManager.default.moveItem(at: sidecar, to: failed)
                Logger(subsystem: "com.callbrain", category: "import")
                    .error("Meet-caption ingest failed; falling back to WhisperKit: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard let helperURL = TranscriptionHelperLocator.helperURL() else {
            throw TranscriptionSidecarError.helperUnavailable(
                Bundle.main.executableURL?.deletingLastPathComponent()
                    .appendingPathComponent(TranscriptionHelperLocator.executableName).path
                ?? TranscriptionHelperLocator.executableName
            )
        }
        let jobID = j.id
        // Strip the " — yyyy-MM-dd HHmm( (N))" disambiguation stamp a recording appends to its filename,
        // so the meeting's title is the clean name ("Partner sync"), not "Partner sync — 2026-07-11 1430".
        let title = IngestEngine.stripRecordingStamp(url.deletingPathExtension().lastPathComponent)
        // Task 2.1: the CALL's date, not the import day — filename first (all real Meet/Drive
        // shapes carry it), file creation date next, today only as the last resort.
        let meta = IngestEngine.filenameMeta(url)
        let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        let ymd = meta.date ?? created.map { TimeCode.ymd($0) } ?? TimeCode.ymd(Date())
        showProgress(jobID, .transcribing, 0.05)
        let sidecarURL = try sidecarOutputURL(jobID: jobID)
        // Dual-channel group attribution (T3): if this recording wrote a clean remote-only sibling, hand it
        // + the founder's name to the sidecar so it labels the founder's turns and diarizes only the remote
        // participants. A non-recording import (no sibling) transcribes mono exactly as before.
        let systemSibling = RecordingSidecars.systemAudioURL(forRecording: url)
        let hasSystem = FileManager.default.fileExists(atPath: systemSibling.path)
        let out: TranscriptionSidecarPayload
        do {
            out = try await runSidecarWithModelFallback(
                helperURL: helperURL, audioURL: url, outputURL: sidecarURL, title: title, date: ymd,
                systemAudioURL: hasSystem ? systemSibling : nil,
                founderName: hasSystem ? FounderIdentity.displayName : nil, jobID: jobID)
        } catch TranscriptionSidecarError.noSpeech {
            // The recording had no detectable speech (silent capture, mic never armed, a paused call).
            // NEVER drop it — that's the founder's real "I can't find the call at all". Create a findable,
            // dated, linkable placeholder meeting so it shows in Meetings and its calendar link + start
            // time still reconcile. Deduped per-file so a retry of the same WAV doesn't spawn duplicates.
            try await ingestNoSpeechPlaceholder(job: &j, url: url, title: title, date: ymd)
            return
        }
        showProgress(jobID, .finishing, 0.9)
        // Vocabulary correction (crypto/company glossary + learned terms) is now applied centrally in
        // IngestEngine.ingest for ALL sources, deduping on the RAW transcript — so just hand it the raw one.
        let outcome = try await env.ingest.ingest(out.transcript)
        j.format = "transcribed"
        j.meetingID = outcome.meetingID
        j.title = out.transcript.title
        j.chunkCount = outcome.chunkCount
        j.state = .done
        let speakerNote = out.diarizationRequested && !out.diarizationSucceeded
            ? " · speakers not identified" : " · \(out.transcript.speakers.count) speaker\(out.transcript.speakers.count == 1 ? "" : "s")"
        j.message = outcome.deduped
            ? "Already imported — this recording matches a call in your library."
            : "Transcribed \(out.transcript.utterances.count) turns\(speakerNote)."
        if !outcome.deduped {
            env.generateTitleIntelligence(for: outcome.meetingID)   // proper AI title + one-liner
            env.summarizeInBackground(outcome.meetingID)            // queue the full Summary-tab pass
            env.classifyInBackground(outcome.meetingID)             // Ambient / Further Health / Other tag
            env.completeMatchingTasks(for: outcome.meetingID)       // auto-complete earlier tasks this call says are done
            env.corpus.scheduleSync()                              // export the new call (re-exports when the summary lands)
            if outcome.embedded == 0, outcome.chunkCount > 0 {
                env.drainPendingEmbeddings()   // same Ollama-down trigger as the text path (gate r2 LOW)
            }
        }
    }

    /// The models the final transcription pass tries, in order. WhisperKit 0.18's greedy sampler uses
    /// `sampleWithMLTensor` unconditionally on macOS 15+ (no runtime opt-out), and CoreML's MLTensor engine
    /// intermittently traps (SIGTRAP → the helper's non-zero "exit 5") on macOS 26 — load-correlated, and
    /// far more often on the heavy `large-v3-turbo` than on the light `base` model (which decodes with far
    /// fewer sampler steps; it's what the live path already uses reliably). So a crash falls back to `base`
    /// instead of losing the recording. `base` stays accurate enough — a slightly-lighter transcript beats
    /// no transcript. Verified root cause: `GreedyTokenSampler.sampleWithMLTensor` → `_assertionFailure`.
    nonisolated static let transcriptionModelChain = ["openai_whisper-large-v3_turbo_954MB", "openai_whisper-base"]

    /// Run the transcription helper, falling back to a lighter model if a heavier one CRASHES (not for a
    /// clean no-speech/helper-missing outcome, which are terminal). Escalates only on `childFailed` — the
    /// crash/error signature — so a genuine "no speech" still becomes a placeholder and a missing helper
    /// still fails fast.
    private func runSidecarWithModelFallback(helperURL: URL, audioURL: URL, outputURL: URL,
                                             title: String, date: String,
                                             systemAudioURL: URL?, founderName: String?,
                                             jobID: String) async throws -> TranscriptionSidecarPayload {
        var lastError: Error = TranscriptionSidecarError.childFailed(status: -1, stderr: "no attempt")
        let models = Self.transcriptionModelChain
        for (i, model) in models.enumerated() {
            do {
                return try await TranscriptionSidecarRunner.run(
                    executableURL: helperURL, audioURL: audioURL, outputURL: outputURL,
                    title: title, date: date, model: model, diarize: true,
                    systemAudioURL: systemAudioURL, founderName: founderName)
            } catch let error as TranscriptionSidecarError where error.isModelSpecificFailure {
                // A child crash/error (e.g. the WhisperKit MLTensor SIGTRAP) — escalate to the next,
                // lighter model. .noSpeech / .helperUnavailable / unreadable-output are NOT model-specific,
                // so they fall through the `where` and propagate as terminal.
                lastError = error
                guard i + 1 < models.count else { break }
                Logger(subsystem: "com.callbrain", category: "import")
                    .error("transcription crashed on \(model, privacy: .public); retrying with \(models[i + 1], privacy: .public)")
                showProgress(jobID, .transcribing, 0.05)   // reset the visible progress for the retry pass
                continue
            }
        }
        throw lastError
    }

    /// Create a findable meeting for a recording that produced no speech, so it's never invisible
    /// (P2c). A single explanatory turn gives it real content to index; deduping on the file PATH
    /// (not the shared placeholder text) keeps two different silent recordings from collapsing into
    /// one, while a re-import of the SAME WAV still dedupes. No AI title/summary — there's nothing
    /// to summarize; the clean filename title + date make it searchable and linkable.
    private func ingestNoSpeechPlaceholder(job j: inout ImportJob, url: URL,
                                           title: String, date: String) async throws {
        let note = ParsedUtterance(seq: 0, speakerRaw: "Recap", tStart: 0, tEnd: 0,
                                   text: "No speech was detected in this recording.")
        let placeholder = ParsedTranscript(title: title, date: date, source: .gmeetLocal,
                                           speakers: ["Recap"], utterances: [note])
        let outcome = try await env.ingest.ingest(placeholder, dedupeFingerprint: "nospeech:\(url.path)")
        j.format = "transcribed"
        j.meetingID = outcome.meetingID
        j.title = title
        j.chunkCount = outcome.chunkCount
        j.state = .done
        j.message = outcome.deduped
            ? "No speech detected — already saved from an earlier import."
            : "No speech detected — saved so you can still find and link this recording."
        // Keep the corpus export in sync but skip title/summary/classify: there's no content to work on.
        if !outcome.deduped { env.corpus.scheduleSync() }
    }

    /// Ingest a recording's relayed Google Meet captions as its transcript (T2). Named turns come
    /// straight from Meet, so no WhisperKit pass or diarization is needed; the WAV stays on disk as the
    /// audio backup and this job's payload is still the WAV path (so notes/calendar-link reconciliation
    /// is unchanged). Vocabulary correction + dedupe happen inside `ingest` like every other source.
    private func ingestCaptions(job j: inout ImportJob, captions: MeetCaptionTranscript,
                                audioURL: URL) async throws {
        showProgress(j.id, .finishing, 0.9)
        let meta = IngestEngine.filenameMeta(audioURL)
        let created = (try? audioURL.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        var parsed = captions.parsed()
        if parsed.title?.isEmpty ?? true { parsed.title = meta.title }
        if parsed.date?.isEmpty ?? true {
            parsed.date = meta.date ?? created.map { TimeCode.ymd($0) } ?? TimeCode.ymd(Date())
        }
        let outcome = try await env.ingest.ingest(parsed)
        j.format = MeetingSource.gmeetCaptions.rawValue
        j.meetingID = outcome.meetingID
        j.title = parsed.title
        j.chunkCount = outcome.chunkCount
        j.state = .done
        let speakers = parsed.speakers.count
        j.message = outcome.deduped
            ? "Already imported — this call matches one in your library."
            : "Used Google Meet captions — \(parsed.utterances.count) turns · \(speakers) speaker\(speakers == 1 ? "" : "s")."
        if !outcome.deduped {
            env.generateTitleIntelligence(for: outcome.meetingID)   // proper AI title + one-liner
            env.summarizeInBackground(outcome.meetingID)            // queue the full Summary-tab pass
            env.classifyInBackground(outcome.meetingID)             // Ambient / Further Health / Other tag
            env.completeMatchingTasks(for: outcome.meetingID)       // auto-complete earlier tasks this call says are done
            env.corpus.scheduleSync()                              // export the new call (re-exports when the summary lands)
            if outcome.embedded == 0, outcome.chunkCount > 0 {
                env.drainPendingEmbeddings()
            }
        }
    }

    private func sidecarOutputURL(jobID: String) throws -> URL {
        let dir = RecordingStorage.directory()
            .appendingPathComponent("TranscriptionSidecars", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(jobID).json")
    }

    /// Live progress for a transcribing job — updates the DISPLAY list in memory (not persisted per tick).
    private func showProgress(_ jobID: String, _ stage: TranscriptionPipeline.Stage, _ frac: Double) {
        guard let i = jobs.firstIndex(where: { $0.id == jobID }), jobs[i].state == .running else { return }
        let label: String
        switch stage {
        case .decoding: label = "Reading audio…"
        case .transcribing: label = frac < 0.1 ? "Transcribing (first run downloads the model)…" : "Transcribing… \(Int(frac * 100))%"
        case .diarizing: label = "Identifying speakers…"
        case .finishing: label = "Finishing…"
        }
        jobs[i].message = label
    }

    // MARK: - helpers

    /// Persist a job and refresh the display list. Returns false (and surfaces `lastError`) on failure
    /// so callers never assume an import was queued when it wasn't (Codex audit: no silent drop).
    @discardableResult
    private func persist(_ job: ImportJob) async -> Bool {
        let store = env.store
        let ok = await Task.detached { (try? store.upsertImportJob(job)) != nil }.value
        if ok { await reload() }
        else { lastError = "Couldn't save the import to the queue." }
        return ok
    }

    /// On launch: a job left in `.running` was interrupted mid-import — requeue it (re-running is
    /// idempotent via content-hash dedupe, so a crash between meeting-commit and job-update self-heals).
    /// Scans the FULL pending set from the store, not the newest-100 display list (re-audit HIGH: an
    /// interrupted job beyond the display cap would otherwise stay stuck `.running` forever).
    private func requeueInterrupted() async {
        let store = env.store
        let running = await Task.detached { ((try? store.pendingImportJobs()) ?? []).filter { $0.state == .running } }.value
        for job in running {
            var j = job
            if j.payloadKind != nil { j.state = .queued; j.message = nil }
            else { j.state = .failed; j.message = "Interrupted (app closed mid-import)." }
            _ = await persist(j)
        }
    }

    /// One-time auto-heal: transcription jobs that FAILED because the WhisperKit helper crashed are now
    /// recoverable via the base-model fallback, so requeue each ONCE — the founder's stuck imports
    /// self-heal on the fixed build without a manual Retry, and without looping (a job that fails AGAIN is
    /// recorded as auto-retried and never requeued a second time). Scoped to media-file jobs whose failure
    /// message names the helper process (the crash signature), so text-import failures are untouched.
    static let autoRetriedTranscriptionKey = "callbrain.autoRetriedTranscriptionJobs"
    private func requeueTranscriptionCrashes() async {
        let store = env.store
        let jobs = await Task.detached { (try? store.importJobs(limit: 500)) ?? [] }.value
        var retried = Set(UserDefaults.standard.stringArray(forKey: Self.autoRetriedTranscriptionKey) ?? [])
        let crashed = jobs.filter { j -> Bool in
            guard j.state == .failed, j.payloadKind == .file, !retried.contains(j.id),
                  let p = j.payload, Self.isMedia(URL(fileURLWithPath: p)),
                  FileManager.default.fileExists(atPath: p),   // the audio must still be on disk to re-run
                  let m = j.message, m.contains("helper process") else { return false }
            return true
        }
        guard !crashed.isEmpty else { return }
        for job in crashed {
            var j = job; j.state = .queued; j.message = nil; j.meetingID = nil; j.chunkCount = 0
            if await persist(j) { retried.insert(job.id) }
        }
        UserDefaults.standard.set(Array(retried), forKey: Self.autoRetriedTranscriptionKey)
        startDraining()
    }

    private func newID() -> String { "j_" + UUID().uuidString }
    private func now() -> Double { Date().timeIntervalSince1970 }

    static func friendly(_ error: Error) -> String {
        switch error {
        case ParseError.empty: return "The file was empty."
        case DocxError.notADocx: return "That doesn't look like a readable .docx file."
        case DocxError.empty, DocxError.noDocumentXML: return "Couldn't find text inside the .docx."
        case IngestError.embeddingCountMismatch:
            return "Embedding service returned the wrong count — is Ollama running?"
        case ReadError.tooLarge(let mb): return "That file is too large to import (\(mb) MB)."
        case AudioDecodeError.noAudioTrack: return "That recording has no audio track to transcribe."
        case AudioDecodeError.tooLong(let hours): return "That recording is too long to transcribe (\(Int(hours))h+)."
        case AudioDecodeError.readFailed(let why): return "Couldn't read the recording's audio: \(why)"
        case TranscribeError.emptyAudio: return "No speech was found in that recording."
        case TranscribeError.modelUnavailable(let why): return "Transcription model unavailable: \(why)"
        case ImportRunError.missingFile(let name): return "“\(name)” has moved or been deleted — re-add it."
        case ImportRunError.noPayload: return "This import had no saved content to process."
        default: return error.localizedDescription
        }
    }
}

enum ImportRunError: Error, Equatable { case missingFile(String); case noPayload }
