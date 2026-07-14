import Foundation
import Observation
import CallBrainCore

/// Main-actor "notes that write themselves" over the currently-recording call (Granola-style).
///
/// Periodically re-summarizes the rolling transcript into a few tight bullets via the WARM local lane
/// (`LiveNotesSource.summarizeLive`). Battery discipline (founder): it only re-summarizes when the
/// transcript has GROWN meaningfully since the last pass (no burning the model on unchanged text), reuses
/// the model the assistant already keeps warm during the call, and NEVER releases the shared model itself —
/// `RecordingModel.stop()` drains it (cancels + awaits its in-flight pass) BEFORE the assistant releases the
/// lane, so nothing can re-pin Ollama after the call ends.
@MainActor
@Observable
public final class LiveNotesModel {
    /// The current rolling notes (most important first). Empty until the first pass lands.
    public private(set) var notes: [NoteLine] = []
    /// True while a summarize pass is in flight (drives a subtle "updating" affordance).
    public private(set) var isWriting = false

    private let source: any LiveNotesSource
    private let transcript: @MainActor () -> String
    /// Note-template instructions that shape the note STRUCTURE (empty → plain bullets).
    private let instructions: String
    private let everySeconds: Double
    private let minGrowthChars: Int
    private let windowChars: Int
    private var loopTask: Task<Void, Never>?
    private var inFlight: Task<Void, Never>?
    private var lastSummarizedLen = 0

    public init(source: LiveNotesSource, transcript: @escaping @MainActor () -> String,
                instructions: String = "",
                everySeconds: Double = 45, minGrowthChars: Int = 350, windowChars: Int = 6000) {
        self.source = source
        self.transcript = transcript
        self.instructions = instructions
        self.everySeconds = max(5, everySeconds)
        self.minGrowthChars = max(0, minGrowthChars)
        self.windowChars = max(0, windowChars)
    }

    /// Begin the periodic note-writing loop.
    public func start() {
        loopTask?.cancel()
        let interval = everySeconds
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                await self?.refreshIfGrown()
            }
        }
    }

    /// Cancel the loop AND any in-flight pass, and AWAIT the in-flight one's unwind — so no summarize
    /// request outlives the call (which would re-pin the shared model after the assistant releases it).
    public func drain() async {
        loopTask?.cancel(); loopTask = nil
        let flight = inFlight; inFlight = nil
        flight?.cancel()
        _ = await flight?.value
        isWriting = false
    }

    /// Run one pass now — only if enough NEW transcript has accrued (or we have no notes yet). Serialized:
    /// never overlaps another pass. Deterministic for tests.
    func refreshIfGrown() async {
        guard inFlight == nil else { return }   // never overlap passes
        let text = transcript()
        // Re-summarize when the transcript CHANGED by a meaningful amount in EITHER direction. Growth is the
        // normal case; a large SHRINK happens when the live source flips mid-call from the on-device You/Them
        // audio to the (shorter) named Meet captions — without the abs() the notes would freeze at stale
        // You/Them text until captions re-grew past the old length. Small caption revisions stay under the
        // threshold, so this never thrashes the model.
        let changedEnough = abs(text.count - lastSummarizedLen) >= minGrowthChars
        guard changedEnough || (notes.isEmpty && !text.isEmpty) else { return }
        lastSummarizedLen = text.count
        let window = String(text.suffix(windowChars))
        // Task inherits @MainActor here; `await summarizeLive` suspends (runs off-main) then resumes on
        // the main actor to publish — no explicit hops needed, no data race.
        let task = Task { [weak self] in
            guard let self else { return }
            self.isWriting = true
            let fresh = await self.source.summarizeLive(transcript: window, instructions: self.instructions)
            self.isWriting = false
            guard !Task.isCancelled, !fresh.isEmpty else { return }
            self.notes = fresh
        }
        inFlight = task
        await task.value
        inFlight = nil   // passes are serialized (guarded above); drain() may have nil'd it already
    }
}
