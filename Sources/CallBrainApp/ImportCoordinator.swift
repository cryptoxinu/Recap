import SwiftUI
import CallBrainCore

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
        reload()
        requeueInterrupted()     // jobs left 'running' by a crash → back to 'queued' so drain resumes them
        startDraining()          // pick up anything still queued from a previous session
    }

    func reload() { jobs = (try? env.store.importJobs()) ?? [] }

    /// True if any of these files has an extension CallBrain can read.
    /// Audio/video files we transcribe on-device (Phase 3) rather than parse as text.
    static let mediaExtensions: Set<String> = ["mp4", "mov", "m4a", "wav", "webm", "mp3", "aac", "caf", "m4v"]
    static func isMedia(_ url: URL) -> Bool { mediaExtensions.contains(url.pathExtension.lowercased()) }

    static func importable(_ urls: [URL]) -> [URL] {
        urls.filter {
            let ext = $0.pathExtension.lowercased()
            return IngestEngine.readableExtensions.contains(ext) || mediaExtensions.contains(ext)
        }
    }

    @discardableResult
    func enqueueFiles(_ urls: [URL]) -> Int { enqueueFilesReturningQueued(urls).count }

    /// Like `enqueueFiles` but returns exactly the URLs that were durably queued, so a caller can record
    /// only what actually succeeded (Drive sync marks only enqueued files as synced — never a file whose
    /// job failed to persist, which would silently drop it forever).
    @discardableResult
    func enqueueFilesReturningQueued(_ urls: [URL]) -> [URL] {
        let files = Self.importable(urls)
        var queued: [URL] = []
        for url in files {
            let job = ImportJob(id: newID(), sourceName: url.lastPathComponent,
                                createdAt: now(), payloadKind: .file, payload: url.path)
            if persist(job) { queued.append(url) }
        }
        if !queued.isEmpty { startDraining() }
        return queued
    }

    /// Archive migration (Phase 7): recursively scan a folder for importable transcripts + recordings and
    /// enqueue them all into this same durable, serially-paced queue. Returns how many were enqueued.
    @discardableResult
    func enqueueFolder(_ folder: URL) -> Int {
        enqueueFiles(Self.scanFolder(folder))
    }

    /// All importable files under a directory (recursive), skipping hidden/package contents.
    static func scanFolder(_ folder: URL, max: Int = 5000) -> [URL] {
        FolderScanner.importableFiles(in: folder,
                                      recognized: IngestEngine.readableExtensions.union(mediaExtensions), max: max)
    }

    /// Returns false if the job couldn't be persisted (so the caller can keep the user's text).
    @discardableResult
    func enqueuePaste(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let job = ImportJob(id: newID(), sourceName: "Pasted text",
                            createdAt: now(), payloadKind: .paste, payload: trimmed)
        guard persist(job) else { return false }
        startDraining()
        return true
    }

    func clearFinished() {
        do { try env.store.clearFinishedImportJobs(); reload() }
        catch { lastError = "Couldn't clear finished imports: \(error.localizedDescription)" }
    }

    func remove(_ job: ImportJob) {
        try? env.store.deleteImportJob(id: job.id)
        reload()
    }

    func confirmReviewed(_ job: ImportJob) {
        var j = job; j.state = .done; j.message = nil; _ = persist(j)
    }

    // MARK: - processing

    private func startDraining() {
        guard !processing else { return }
        processing = true
        // Defeat App Nap + idle sleep while importing/transcribing so jobs finish even if the user steps
        // away or closes the window (Phase 6). The token is released when the queue drains.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Importing calls")
        Task {
            await drain()
            processing = false
            ProcessInfo.processInfo.endActivity(activity)
        }
    }

    private func drain() async {
        // Pull the full pending set from the store each pass (not the display list) so a large backlog
        // fully drains and newly-enqueued jobs are seen.
        while let job = (try? env.store.pendingImportJobs())?.first(where: { $0.state == .queued }) {
            await run(job)
        }
        env.refreshReminders()   // new imports can add tasks → keep the reminder count fresh
    }

    private func run(_ job: ImportJob) async {
        var j = job; j.state = .running; _ = persist(j)

        do {
            // Media file → on-device transcription path (decode → WhisperKit → FluidAudio → ingest).
            if job.payloadKind == .file, let path = job.payload, Self.isMedia(URL(fileURLWithPath: path)) {
                try await runTranscription(job: &j, path: path)
                _ = persist(j)
                return
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
            }
            _ = persist(j)
        } catch {
            j.state = .failed
            j.message = Self.friendly(error)
            _ = persist(j)
        }
    }

    /// Transcribe a media file on-device, then ingest the result like any other meeting.
    private func runTranscription(job j: inout ImportJob, path: String) async throws {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            throw ImportRunError.missingFile(url.lastPathComponent)
        }
        let jobID = j.id
        let title = url.deletingPathExtension().lastPathComponent
        let out = try await env.transcription.run(url: url, title: title, date: TimeCode.ymd(Date())) {
            [weak self] stage, frac in
            Task { @MainActor in self?.showProgress(jobID, stage, frac) }
        }
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
        }
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
    private func persist(_ job: ImportJob) -> Bool {
        do { try env.store.upsertImportJob(job); reload(); return true }
        catch {
            lastError = "Couldn't save the import to the queue: \(error.localizedDescription)"
            return false
        }
    }

    /// On launch: a job left in `.running` was interrupted mid-import — requeue it (re-running is
    /// idempotent via content-hash dedupe, so a crash between meeting-commit and job-update self-heals).
    /// Scans the FULL pending set from the store, not the newest-100 display list (re-audit HIGH: an
    /// interrupted job beyond the display cap would otherwise stay stuck `.running` forever).
    private func requeueInterrupted() {
        let running = ((try? env.store.pendingImportJobs()) ?? []).filter { $0.state == .running }
        for job in running {
            var j = job
            if j.payloadKind != nil { j.state = .queued; j.message = nil }
            else { j.state = .failed; j.message = "Interrupted (app closed mid-import)." }
            _ = persist(j)
        }
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
