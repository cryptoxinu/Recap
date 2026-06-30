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
    static func importable(_ urls: [URL]) -> [URL] {
        urls.filter { IngestEngine.readableExtensions.contains($0.pathExtension.lowercased()) }
    }

    @discardableResult
    func enqueueFiles(_ urls: [URL]) -> Int {
        let files = Self.importable(urls)
        var enqueued = 0
        for url in files {
            let job = ImportJob(id: newID(), sourceName: url.lastPathComponent,
                                createdAt: now(), payloadKind: .file, payload: url.path)
            if persist(job) { enqueued += 1 }
        }
        if enqueued > 0 { startDraining() }
        return enqueued
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
        Task { await drain(); processing = false }
    }

    private func drain() async {
        // Pull the full pending set from the store each pass (not the display list) so a large backlog
        // fully drains and newly-enqueued jobs are seen.
        while let job = (try? env.store.pendingImportJobs())?.first(where: { $0.state == .queued }) {
            await run(job)
        }
    }

    private func run(_ job: ImportJob) async {
        var j = job; j.state = .running; _ = persist(j)

        do {
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
            _ = persist(j)
        } catch {
            j.state = .failed
            j.message = Self.friendly(error)
            _ = persist(j)
        }
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
    private func requeueInterrupted() {
        for job in jobs where job.state == .running {
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
        case ImportRunError.missingFile(let name): return "“\(name)” has moved or been deleted — re-add it."
        case ImportRunError.noPayload: return "This import had no saved content to process."
        default: return error.localizedDescription
        }
    }
}

enum ImportRunError: Error, Equatable { case missingFile(String); case noPayload }
