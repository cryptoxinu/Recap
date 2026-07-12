import Foundation
import WhisperKit
import CallBrainCore

private actor TranscribeGate {
    private var tail: Task<Void, Never> = Task {}

    func run<T: Sendable>(_ body: @Sendable @escaping () async throws -> T) async throws -> T {
        let prev = tail
        let work = Task { () async throws -> T in
            _ = await prev.value
            return try await body()
        }
        tail = Task { _ = try? await work.value }
        return try await work.value
    }
}

/// `Transcriber` backed by WhisperKit (CoreML Whisper, on-device). The model is downloaded + compiled on
/// first use and cached on DISK (shared across instances); subsequent runs reuse the compiled model.
///
/// Two use sites with DIFFERENT needs (dual-answer spec P0):
/// - **Live rolling path** wants a small, ALWAYS-CACHED model (`openai_whisper-base`) so partials appear
///   instantly. It stays warm across the ~1.5s ticks of a call (`unloadAfterEach: false`) and is released
///   explicitly at record-stop. It may bootstrap-download its OWN small model on a fresh machine, but the
///   load path NEVER downloads a large model.
/// - **Final post-call pass** wants the high-accuracy `openai_whisper-large-v3_turbo_954MB`. Its load path
///   is CACHED-ONLY (`allowDownload: false`) so it can NEVER block on a 954MB fetch — the turbo model is
///   fetched ahead of time in the background (`ensureDownloaded`). It loads per-pass and unloads right
///   after (`unloadAfterEach: true`), so (a) the 954MB model never stays resident after a recording and
///   (b) each pass re-resolves, upgrading base→turbo the moment the background download lands.
public final class WhisperKitTranscriber: CallBrainCore.Transcriber, @unchecked Sendable {
    public let modelID: String
    private let modelName: String
    private let fallbacks: [String]
    private let allowDownload: Bool
    private let unloadAfterEach: Bool
    /// Vocabulary-biasing prompt (crypto/company glossary), read fresh per pass so a just-edited glossary
    /// takes effect immediately. Tokenized + passed as Whisper `promptTokens` so the model is nudged to
    /// HEAR these terms correctly at the source (the "Otter-style custom vocabulary" mechanism). Empty = off.
    private let biasPromptProvider: @Sendable () -> String
    // Lock-guarded one-shot init Task: concurrent callers share a single load (no double-init / data
    // race on the model — Codex P3 gate MED). Safe to cache + reuse one instance across recordings.
    private let lock = NSLock()
    private var loadTask: Task<Box<WhisperKit>, Error>?
    private var loadGeneration = 0   // bumps per load attempt, so a FAILED task can be cleared safely
    private let transcribeGate = TranscribeGate()

    /// - Parameters:
    ///   - model: the preferred model.
    ///   - fallbacks: cached models to fall back to (in order) if the preferred one isn't loadable.
    ///   - allowDownload: if true, a blocking download of the PREFERRED model is the last resort (after
    ///     every cached fallback). Only safe when the preferred model is SMALL (e.g. base 140MB). Keep
    ///     FALSE whenever the preferred model is large so the load can never stall on a network fetch.
    ///   - unloadAfterEach: release the model right after each `transcribe`. True for the infrequent
    ///     final pass (no lifetime residency, auto-upgrades to a newly-cached model); false for the live
    ///     path (stays warm across ticks; released explicitly via `unload()` at record-stop).
    public init(model: String = "openai_whisper-large-v3_turbo_954MB",
                fallbacks: [String] = ["openai_whisper-base", "openai_whisper-tiny"],
                allowDownload: Bool = true,
                unloadAfterEach: Bool = false,
                biasPrompt: @escaping @Sendable () -> String = { "" }) {
        self.modelName = model
        self.fallbacks = fallbacks
        self.allowDownload = allowDownload
        self.unloadAfterEach = unloadAfterEach
        self.biasPromptProvider = biasPrompt
        self.modelID = "whisperkit-\(model)"
    }

    public func transcribe(_ samples: [Float],
                           progress: @Sendable @escaping (Double) -> Void) async throws -> [TranscribedSegment] {
        let wk = Box(try await ensure())
        // Release the model after this pass when configured, so a large final-pass model never stays
        // resident (founder: nothing should linger draining battery/memory once a recording is done).
        defer { if unloadAfterEach { unload() } }
        let biasPrompt = biasPromptProvider()
        return try await transcribeGate.run {
            progress(0.05)
            // Vocabulary biasing: tokenize the glossary and pass it as the decoder's conditioning prompt
            // so Whisper is nudged to hear "Ethereum"/"Solana"/company terms correctly. WhisperKit trims
            // the prompt to its own token budget; a leading space matches how prompts are tokenized.
            var options: DecodingOptions? = nil
            if !biasPrompt.isEmpty, let tokens = wk.value.tokenizer?.encode(text: " " + biasPrompt), !tokens.isEmpty {
                options = DecodingOptions(promptTokens: tokens)   // usePrefillPrompt defaults true
            }
            let results = options != nil
                ? try await wk.value.transcribe(audioArray: samples, decodeOptions: options)
                : try await wk.value.transcribe(audioArray: samples)
            progress(0.98)
            return results.flatMap(\.segments).compactMap { seg in
                let text = Self.cleanSegmentText(seg.text)
                guard !text.isEmpty else { return nil }
                return TranscribedSegment(text: text, tStart: Double(seg.start), tEnd: Double(seg.end))
            }
        }
    }

    public func prewarm() async { _ = try? await ensure() }

    /// Release the loaded model (drops the cached `WhisperKit` → CoreML unloads it). The next call
    /// reloads (and re-resolves the preferred model, so a newly-downloaded turbo is picked up). An
    /// in-flight `transcribe` already holds its own reference and completes safely.
    public func unload() {
        lock.withLock { loadTask = nil }
    }

    private func ensure() async throws -> WhisperKit {
        let (task, generation): (Task<Box<WhisperKit>, Error>, Int) = lock.withLock {
            if let t = loadTask { return (t, loadGeneration) }
            loadGeneration += 1
            let gen = loadGeneration
            let t = Task { [modelName, fallbacks, allowDownload] () throws -> Box<WhisperKit> in
                let primary = Self.effectiveModelName(for: modelName)
                let compute = ModelComputeOptions(audioEncoderCompute: .cpuAndNeuralEngine,
                                                  textDecoderCompute: .cpuAndNeuralEngine)
                // Preferred model first, then the cached fallbacks. For EACH we try, in order:
                //   1. Load from the model's LOCAL folder if it's fully downloaded — no network, works
                //      offline, and (unlike bare `download:false`) never errors "Model folder is not set".
                //   2. Otherwise, if downloads are allowed for this transcriber, fetch it (network). The
                //      live path only lists small models, so this never blocks on a large download.
                var lastError: Error?
                for name in [primary] + fallbacks {
                    if let folder = Self.cachedModelFolder(name) {
                        let config = WhisperKitConfig(model: name, modelFolder: folder,
                                                      computeOptions: compute, prewarm: true, download: false)
                        if let wk = try? await WhisperKit(config) { return Box(wk) }
                    }
                    if allowDownload {
                        let config = WhisperKitConfig(model: name, computeOptions: compute,
                                                      prewarm: true, download: true)
                        do { return Box(try await WhisperKit(config)) }
                        catch { lastError = error; continue }
                    }
                }
                // Last resort so a recording NEVER fails silently: download the SMALLEST fallback (fast,
                // ~70-140MB) — never the large primary, so a fresh/uncached final pass can't block minutes
                // on a 954MB fetch here (the background prefetch handles turbo). WhisperKit resolves it its
                // own way (default cache + download), which also fetches the tokenizer if missing.
                let bootstrap = Self.effectiveModelName(for: fallbacks.last ?? primary)
                do {
                    return Box(try await WhisperKit(WhisperKitConfig(model: bootstrap, computeOptions: compute,
                                                                    prewarm: true, download: true)))
                } catch {
                    throw TranscribeError.modelUnavailable("WhisperKit: no usable model (\((lastError ?? error).localizedDescription))")
                }
            }
            loadTask = t
            return (t, gen)
        }
        do {
            return try await task.value.value
        } catch {
            // A FAILED load must not be cached forever — after coming back online or a model finishing
            // download, a later recording must be able to retry. Clear it only if no newer load started
            // (generation guard), since concurrent callers share the single-flight task (audit HIGH).
            lock.withLock { if loadGeneration == generation { loadTask = nil } }
            throw error
        }
    }

    /// Best-effort BACKGROUND download of a model so a LATER load finds it cached and never blocks. Safe
    /// to call repeatedly (WhisperKit's snapshot download resumes/no-ops when already present). Returns
    /// true when the model is available afterward, false on a stalled/offline fetch (so the caller can
    /// retry later) — never throws.
    @discardableResult
    public static func ensureDownloaded(_ model: String) async -> Bool {
        let name = effectiveModelName(for: model)
        let config = WhisperKitConfig(model: name, prewarm: false, download: true)
        return (try? await WhisperKit(config)) != nil
    }

    /// Whisper's special tokens (`<|…|>`) AND its non-speech MARKERS (`[BLANK_AUDIO]`, `[ Silence ]`,
    /// `[INAUDIBLE]`, `(music)`, …) leak into segment text and pollute the transcript, the AI answers
    /// ("…followed by blank audio"), and the AI notes. Strip both, then collapse the whitespace they leave.
    static func cleanSegmentText(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: #"<\|[^>]*\|>"#, with: "", options: .regularExpression)
        let markers = #"[\[\(]\s*(blank[\s_]?audio|silences?|inaudible|no[\s_]?speech|noise|music( playing)?|pause|crosstalk|laughter|applause|background[\s_]?noise|typing|beep|sound)\s*[\]\)]"#
        text = text.replacingOccurrences(of: markers, with: "", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func effectiveModelName(for requestedModel: String) -> String {
        let modelSupport = WhisperKit.recommendedModels()
        guard modelSupport.supported.contains(requestedModel) else { return modelSupport.default }
        return requestedModel
    }

    /// WhisperKit's default download location (…/Documents/huggingface/models/argmaxinc/whisperkit-coreml).
    private static func modelsBaseFolder() -> URL {
        let docs = (try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: false))
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Documents")
        return docs.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml", isDirectory: true)
    }

    /// The local folder for `model` IF it is FULLY downloaded (carries the compiled sub-models). Returns
    /// nil for a missing or half-downloaded (stalled-shell) model so the caller fetches it instead. Loading
    /// via this folder is offline-safe and avoids the "Model folder is not set" error of bare download:false.
    private static func cachedModelFolder(_ model: String) -> String? {
        let dir = modelsBaseFolder().appendingPathComponent(model, isDirectory: true)
        let fm = FileManager.default
        let required = ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"]
        guard required.allSatisfy({ fm.fileExists(atPath: dir.appendingPathComponent($0).path) }) else { return nil }
        return dir.path
    }

    /// Whether `model` is FULLY downloaded on disk — a pure check (no fetch) so the app can drive a live
    /// "downloading / ready" status for the accurate-transcription toggle.
    public static func isModelCached(_ model: String) -> Bool { cachedModelFolder(model) != nil }
}
