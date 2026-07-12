import Foundation

/// The INSTANT lane for the in-call assistant (dual-answer spec P1).
///
/// Talks to the persistent local Ollama server (`127.0.0.1:11434`) which keeps a small model
/// (`qwen2.5:3b`) resident in unified memory — so answers stream in with NO process spawn, NO auth,
/// NO network egress. That is the whole point: the CLI "smart" lane cold-spawns `claude -p` (2–6s);
/// this warm local lane yields a first token in tens of ms.
///
/// Battery/residency discipline (founder requirement — nothing may linger draining the Mac):
/// - This provider NEVER launches `ollama serve`. It only makes HTTP requests; if the server isn't
///   already running the request fails fast and the caller degrades to Smart-only. We do not spin
///   Ollama up in the background.
/// - `keepAlive` is modest (default 5m) so an unused model self-evicts, and the recording lifecycle
///   HARD-unloads the model at record-stop via `OllamaSummarizer.unload(model:)`. The model is warm
///   ONLY while a call is actually using it.
public struct OllamaLiveProvider: LLMProvider {
    public nonisolated var id: ProviderID { .ollama }

    public let model: String
    public let baseURL: URL
    /// Small context is enough for a live recap over a recent window; keeps first-token latency low.
    public let numCtx: Int
    /// Cap the reply — the live prompt asks for one sentence / a few tight bullets.
    public let numPredict: Int
    public let temperature: Double
    /// How long Ollama keeps the model resident after a call. Modest by design so an idle model
    /// self-evicts; the recording stop path also unloads explicitly.
    public let keepAlive: String
    /// Test seam: extra `URLProtocol` classes to register on the session (canned responses). Empty in
    /// production. `@unchecked Sendable`-safe because it's an immutable array of metatypes.
    private let extraProtocolClasses: [AnyClass]

    public init(model: String = "qwen2.5:3b",
                baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
                numCtx: Int = 4096, numPredict: Int = 220,
                temperature: Double = 0.2, keepAlive: String = "2m",
                extraProtocolClasses: [AnyClass] = []) {
        self.model = model; self.baseURL = baseURL
        self.numCtx = numCtx; self.numPredict = numPredict
        // Modest keep_alive: warm for the back-and-forth of an ACTIVE call, but self-evicts after a
        // couple idle minutes so nothing lingers. The recording lifecycle also HARD-unloads at stop
        // (`unload()`), so the resident window is bounded by the call, not by this value (audit HIGH).
        self.temperature = temperature; self.keepAlive = keepAlive
        self.extraProtocolClasses = extraProtocolClasses
    }

    private func session(timeout: TimeInterval) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        // `timeoutIntervalForRequest` is the max idle time between bytes (streaming INACTIVITY). Cap the
        // TOTAL request at the same budget so a trickling server can't occupy the fast lane far longer
        // than the caller asked (audit MED: no more inactivity×4 wall-clock). fail-fast when down.
        cfg.timeoutIntervalForRequest = max(3, timeout)
        cfg.timeoutIntervalForResource = max(6, timeout)
        cfg.waitsForConnectivity = false
        if !extraProtocolClasses.isEmpty {
            cfg.protocolClasses = extraProtocolClasses + (cfg.protocolClasses ?? [])
        }
        return URLSession(configuration: cfg)
    }

    private func requestBody(prompt: String, system: String?, stream: Bool, format: Any?) -> Data? {
        let options: [String: Any] = [
            "temperature": temperature, "num_ctx": numCtx,
            "num_predict": numPredict, "repeat_penalty": 1.1,
        ]
        var payload: [String: Any] = [
            "model": model, "prompt": prompt, "stream": stream, "keep_alive": keepAlive,
            "options": options,
        ]
        if let system, !system.isEmpty { payload["system"] = system }
        if let format { payload["format"] = format }
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    private func generateURL() -> URL { baseURL.appendingPathComponent("api/generate") }

    /// HARD-unload the model from Ollama (`keep_alive: 0`) so it stops holding unified memory / drawing
    /// power the moment a call ends. Best-effort; a down server is a silent no-op. We NEVER start the
    /// server — this only tells an already-running Ollama to evict.
    public func unload() async {
        var req = URLRequest(url: generateURL())
        req.httpMethod = "POST"
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model, "keep_alive": 0, "prompt": "",
        ])
        _ = try? await session(timeout: 10).data(for: req)
    }

    /// Synchronous best-effort unload for app TERMINATION, where an async task has no time to run. Bounded
    /// (~1.5s) so quit stays snappy. Belt-and-suspenders for the founder's "nothing stays resident" rule:
    /// if a recording was still active at quit, evict the live model now. No-op when Ollama is down.
    public static func unloadSyncBestEffort(model: String,
                                            baseURL: URL = URL(string: "http://127.0.0.1:11434")!) {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        req.httpMethod = "POST"
        req.timeoutInterval = 1.5
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model, "keep_alive": 0, "prompt": "",
        ])
        let sem = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: req) { _, _, _ in sem.signal() }
        task.resume()
        _ = sem.wait(timeout: .now() + 1.6)
    }

    // MARK: LLMProvider

    public func complete(prompt: String, system: String?, model _: String,
                         timeout: TimeInterval) async throws -> Completion {
        var req = URLRequest(url: generateURL())
        req.httpMethod = "POST"
        req.httpBody = requestBody(prompt: prompt, system: system, stream: false, format: nil)
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session(timeout: timeout).data(for: req) }
        catch { throw Self.mapError(error, timeout: timeout) }
        try Self.checkStatus(resp)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["response"] as? String else {
            throw LLMError.decodeFailed("Ollama: unreadable response")
        }
        return Completion(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                          provider: .ollama, model: self.model, usage: TokenUsage(), costUSD: 0)
    }

    public func completeJSON(prompt: String, system: String?, schema: String,
                             model _: String, timeout: TimeInterval) async throws -> String {
        var req = URLRequest(url: generateURL())
        req.httpMethod = "POST"
        let format: Any = (schema.data(using: .utf8)).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? "json"
        req.httpBody = requestBody(prompt: prompt, system: system, stream: false, format: format)
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session(timeout: timeout).data(for: req) }
        catch { throw Self.mapError(error, timeout: timeout) }
        try Self.checkStatus(resp)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["response"] as? String else {
            throw LLMError.decodeFailed("Ollama: unreadable response")
        }
        return text
    }

    public func streamComplete(prompt: String, system: String?, model _: String,
                               timeout: TimeInterval) -> AsyncThrowingStream<StreamEvent, Error> {
        let body = requestBody(prompt: prompt, system: system, stream: true, format: nil)
        let url = generateURL()
        let session = session(timeout: timeout)
        let model = self.model
        let deadline = timeout
        return AsyncThrowingStream { continuation in
            let task = Task {
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.httpBody = body
                do {
                    let (bytes, resp) = try await session.bytes(for: req)
                    try Self.checkStatus(resp)
                    var acc = ""
                    var sawFirst = false
                    // Ollama streams newline-delimited JSON objects: {"response":"…","done":false} …
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard let data = line.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }
                        if let piece = obj["response"] as? String, !piece.isEmpty {
                            if !sawFirst { continuation.yield(.ready); sawFirst = true }
                            acc += piece
                            continuation.yield(.delta(piece))
                        }
                        if (obj["done"] as? Bool) == true { break }
                    }
                    let completion = Completion(text: acc.trimmingCharacters(in: .whitespacesAndNewlines),
                                                provider: .ollama, model: model, usage: TokenUsage(), costUSD: 0)
                    continuation.yield(.done(completion))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.mapError(error, timeout: deadline))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Errors

    private static func checkStatus(_ resp: URLResponse) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            // 404 == model not pulled; surface a clean, actionable message.
            if http.statusCode == 404 {
                throw LLMError.notInstalled("Ollama model not found — pull it with `ollama pull`.")
            }
            throw LLMError.providerError(subtype: "ollama_http_\(http.statusCode)", detail: "Ollama returned HTTP \(http.statusCode).")
        }
    }

    /// Map a URLSession failure (server down, refused, timed out) to a clean LLMError so the caller can
    /// degrade to Smart-only with a real message instead of a bridged Foundation string. `timeout` is the
    /// budget that was requested, so a timeout surfaces the real number (not 0) in UI/telemetry.
    private static func mapError(_ error: Error, timeout: TimeInterval = 0) -> Error {
        if error is LLMError { return error }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut:
                return LLMError.timedOut(seconds: Int(timeout.rounded()))
            case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost,
                 NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet:
                return LLMError.launchFailed("Ollama isn't running (no server at 127.0.0.1:11434).")
            default:
                return LLMError.launchFailed(ns.localizedDescription)
            }
        }
        return LLMError.launchFailed(error.localizedDescription)
    }
}
