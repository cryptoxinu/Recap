import SwiftUI
import CallBrainCore

/// Drives the durable import queue (Phase 2). Files and pasted text become persisted `ImportJob`s and
/// are processed **serially** (so Ollama/claude aren't hammered by a multi-file drop). State transitions
/// are written through to the store, so the queue survives relaunch and a crash mid-backfill is visible.
@MainActor
@Observable
final class ImportCoordinator {
    private let env: AppEnvironment
    private(set) var jobs: [ImportJob] = []
    private(set) var processing = false
    /// Files/text that haven't been imported yet aren't fully persisted (a path can move; pasted text is
    /// ephemeral) — the live payload lives here for this session only.
    private var payloads: [String: Payload] = [:]

    enum Payload { case file(URL); case paste(String) }

    init(env: AppEnvironment) {
        self.env = env
        reload()
        markInterruptedJobs()   // any queued/running rows left by a prior crash can't auto-resume
    }

    func reload() { jobs = (try? env.store.importJobs()) ?? [] }

    /// True if any of these files has an extension CallBrain can read.
    static func importable(_ urls: [URL]) -> [URL] {
        urls.filter { IngestEngine.readableExtensions.contains($0.pathExtension.lowercased()) }
    }

    @discardableResult
    func enqueueFiles(_ urls: [URL]) -> Int {
        let files = Self.importable(urls)
        for url in files {
            let job = ImportJob(id: newID(), sourceName: url.lastPathComponent,
                                createdAt: Date().timeIntervalSince1970)
            payloads[job.id] = .file(url)
            persist(job)
        }
        if !files.isEmpty { startDraining() }
        return files.count
    }

    func enqueuePaste(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let job = ImportJob(id: newID(), sourceName: "Pasted text",
                            createdAt: Date().timeIntervalSince1970)
        payloads[job.id] = .paste(trimmed)
        persist(job)
        startDraining()
    }

    func clearFinished() {
        try? env.store.clearFinishedImportJobs()
        reload()
    }

    func remove(_ job: ImportJob) {
        try? env.store.deleteImportJob(id: job.id)
        payloads[job.id] = nil
        reload()
    }

    // MARK: - processing

    private func startDraining() {
        guard !processing else { return }
        processing = true
        Task { await drain(); processing = false }
    }

    private func drain() async {
        // Process queued jobs (in creation order) until none remain with a live payload.
        while let job = nextQueued() {
            await run(job)
        }
    }

    private func nextQueued() -> ImportJob? {
        jobs.filter { $0.state == .queued && payloads[$0.id] != nil }
            .min { $0.createdAt < $1.createdAt }
    }

    private func run(_ job: ImportJob) async {
        guard let payload = payloads[job.id] else { return }
        var j = job; j.state = .running; persist(j)

        do {
            let (outcome, resolved): (IngestEngine.Outcome, AIImporter.Resolved)
            switch payload {
            case .file(let url): (outcome, resolved) = try await env.ingest.ingestFile(at: url, importer: env.importer)
            case .paste(let text): (outcome, resolved) = try await env.ingest.ingestRaw(text, importer: env.importer)
            }
            j.format = resolved.format.rawValue
            j.usedAI = resolved.usedAI
            j.meetingID = outcome.meetingID
            j.title = resolved.transcript.title
            j.chunkCount = outcome.chunkCount
            if outcome.deduped {
                // Identical content already in the library — not an error, just nothing new to do.
                j.state = .done
                j.message = "Already imported — this matches a call already in your library."
            } else if resolved.usedAI {
                // AI-resolved (unknown layout) → ask the human to confirm the structure.
                j.state = .needsReview
                j.message = "AI structured this — open it to confirm speakers/turns look right."
            } else {
                j.state = .done
                j.message = nil
            }
            persist(j)
        } catch {
            j.state = .failed
            j.message = Self.friendly(error)
            persist(j)
        }
        payloads[job.id] = nil
    }

    func confirmReviewed(_ job: ImportJob) {
        var j = job; j.state = .done; j.message = nil; persist(j)
    }

    // MARK: - helpers

    private func persist(_ job: ImportJob) {
        try? env.store.upsertImportJob(job)
        reload()
    }

    private func markInterruptedJobs() {
        for job in jobs where job.state == .queued || job.state == .running {
            var j = job; j.state = .failed
            j.message = "Interrupted (app closed mid-import). Re-import the file."
            try? env.store.upsertImportJob(j)
        }
        reload()
    }

    private func newID() -> String { "j_" + UUID().uuidString }

    static func friendly(_ error: Error) -> String {
        switch error {
        case ParseError.empty: return "The file was empty."
        case DocxError.notADocx: return "That doesn't look like a readable .docx file."
        case DocxError.empty, DocxError.noDocumentXML: return "Couldn't find text inside the .docx."
        case IngestError.embeddingCountMismatch:
            return "Embedding service returned the wrong count — is Ollama running?"
        default: return error.localizedDescription
        }
    }
}
