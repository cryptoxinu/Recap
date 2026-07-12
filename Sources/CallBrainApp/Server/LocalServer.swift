import Foundation
import Network
import os
import CallBrainAppCore
import CallBrainCore

/// Persistent loopback HTTP server used by the Chrome extension bridge.
///
/// Security posture:
/// - Binds only `127.0.0.1` using `requiredLocalEndpoint`.
/// - Drops accepted connections whose remote endpoint is not loopback.
/// - Requires the shared bearer token on every non-`OPTIONS` request.
/// - Applies fixed header/body caps before parsing JSON or calling app services.
final class LocalServer: @unchecked Sendable {
    private static let fallbackPortCount: UInt16 = 10
    private static let receiveChunkBytes = 16 * 1_024
    private static let defaultMaxActiveConnections = 32
    private static let defaultRequestReadTimeout: TimeInterval = 15
    private static let log = Logger(subsystem: "com.callbrain", category: "local-server")

    private let token: String
    private let ask: any LiveAsk
    private let session: MeetSession
    private let onImport: @Sendable (String) async -> Bool
    private let onMeetMuted: @Sendable (Bool) async -> Void
    private let onRecordStart: @Sendable () async -> Bool
    private let onRecordStop: @Sendable () async -> Void
    private let recordStatus: @Sendable () async -> RecordStatusSnapshot
    private let onPaired: @Sendable () async -> Void
    /// When set + in the future, `/pair` will hand the token to a chrome-extension origin ONCE. Opened by
    /// the user from Settings → "Pair extension"; closed by default and on first success (lock-guarded).
    private var pairingDeadline: Date?
    private let preferredPort: UInt16
    private let maxActiveConnections: Int
    private let requestReadTimeout: TimeInterval
    private let queue = DispatchQueue(label: "com.callbrain.local-server", qos: .userInitiated)
    private let lock = NSLock()

    private var listener: NWListener?
    private var boundPort: UInt16?
    private var connections: [UUID: ServerConnection] = [:]

    var port: UInt16? {
        lock.withLock { boundPort }
    }

    /// Open a short auto-pair window (user-initiated from Settings). While it's open, `/pair` hands the token
    /// to a chrome-extension origin so the extension can pair without the user copy-pasting anything.
    func openPairingWindow(seconds: TimeInterval = 120) {
        lock.withLock { pairingDeadline = Date().addingTimeInterval(seconds) }
    }

    init(token: String, ask: any LiveAsk, session: MeetSession,
         onImport: @escaping @Sendable (String) async -> Bool,
         onMeetMuted: @escaping @Sendable (Bool) async -> Void,
         onRecordStart: @escaping @Sendable () async -> Bool = { false },
         onRecordStop: @escaping @Sendable () async -> Void = {},
         recordStatus: @escaping @Sendable () async -> RecordStatusSnapshot
            = { RecordStatusSnapshot(recording: false, processing: false, elapsed: "0:00") },
         onPaired: @escaping @Sendable () async -> Void = {},
         preferredPort: UInt16 = 8_422,
         maxActiveConnections: Int = LocalServer.defaultMaxActiveConnections,
         requestReadTimeout: TimeInterval = LocalServer.defaultRequestReadTimeout) {
        self.token = token
        self.ask = ask
        self.session = session
        self.onImport = onImport
        self.onMeetMuted = onMeetMuted
        self.onRecordStart = onRecordStart
        self.onRecordStop = onRecordStop
        self.recordStatus = recordStatus
        self.onPaired = onPaired
        self.preferredPort = preferredPort
        self.maxActiveConnections = max(1, maxActiveConnections)
        self.requestReadTimeout = max(1, requestReadTimeout)
    }

    /// Bind to the preferred loopback port or the next few ports, then begin accepting connections.
    func start() async throws -> UInt16 {
        if let existing = port { return existing }

        var lastError: Error?
        for candidate in candidatePorts(startingAt: preferredPort) {
            var candidateListener: NWListener?
            do {
                let listener = try makeListener(port: candidate)
                candidateListener = listener
                lock.withLock {
                    self.listener = listener
                    self.boundPort = nil
                }
                let startedPort = try await start(listener: listener, requestedPort: candidate)
                lock.withLock {
                    self.boundPort = startedPort
                }
                return startedPort
            } catch {
                lastError = error
                candidateListener?.cancel()
                lock.withLock {
                    self.listener = nil
                    self.boundPort = nil
                }
            }
        }

        throw lastError ?? LocalServerError.noPortAvailable
    }

    /// Stop accepting new connections and close all active request connections.
    func stop() {
        let snapshot: [ServerConnection] = lock.withLock {
            let current = Array(connections.values)
            connections = [:]
            boundPort = nil
            let activeListener = listener
            listener = nil
            activeListener?.cancel()
            return current
        }
        for connection in snapshot {
            connection.cancel()
        }
    }

    private func candidatePorts(startingAt start: UInt16) -> [UInt16] {
        let upper = min(UInt32(start) + UInt32(Self.fallbackPortCount), UInt32(UInt16.max))
        return (UInt32(start)...upper).map { UInt16($0) }
    }

    private func makeListener(port: UInt16) throws -> NWListener {
        let parameters = NWParameters.tcp
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw LocalServerError.invalidPort }
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: endpointPort)
        return try NWListener(using: parameters)
    }

    private func start(listener: NWListener, requestedPort: UInt16) async throws -> UInt16 {
        let gate = StartGate()
        let boxedListener = ListenerBox(listener)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            gate.arm(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.resume(.success(boxedListener.raw.port?.rawValue ?? requestedPort))
                case .failed(let error):
                    gate.resume(.failure(error))
                case .cancelled:
                    gate.resume(.failure(LocalServerError.cancelled))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
        }
    }

    private func handle(_ rawConnection: NWConnection) {
        guard Self.isLoopback(rawConnection.endpoint) else {
            rawConnection.cancel()
            return
        }

        let id = UUID()
        let connection = ServerConnection(id: id, raw: rawConnection) { [weak self] id in
            self?.removeConnection(id)
        }
        let accepted = lock.withLock {
            guard connections.count < maxActiveConnections else { return false }
            connections = connections.merging([id: connection]) { _, new in new }
            return true
        }
        guard accepted else {
            rawConnection.cancel()
            return
        }

        connection.scheduleReadDeadline(seconds: requestReadTimeout, queue: queue)
        rawConnection.stateUpdateHandler = { [weak connection] state in
            switch state {
            case .failed, .cancelled:
                connection?.cancel()
            default:
                break
            }
        }
        rawConnection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func removeConnection(_ id: UUID) {
        lock.withLock {
            let next = connections.filter { $0.key != id }
            connections = next
        }
    }

    private func receive(on connection: ServerConnection, buffer: Data) {
        connection.raw.receive(minimumIncompleteLength: 1, maximumLength: Self.receiveChunkBytes) {
            [weak self, connection] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            guard error == nil else {
                connection.cancel()
                return
            }

            var next = buffer
            if let data {
                next.append(data)
            }

            switch self.readDecision(for: next) {
            case .needMore:
                if isComplete {
                    self.sendAndClose(.badRequest(), on: connection)
                } else {
                    self.receive(on: connection, buffer: next)
                }
            case .ready(let request):
                connection.clearReadDeadline()
                Task.detached(priority: .userInitiated) {
                    await self.respond(to: request, on: connection)
                }
            case .tooLarge:
                self.sendAndClose(.payloadTooLarge(), on: connection)
            case .badRequest:
                self.sendAndClose(.badRequest(), on: connection)
            }
        }
    }

    private func readDecision(for data: Data) -> ReadDecision {
        guard let terminator = data.range(of: LocalServerLimits.headerTerminator) else {
            return data.count > LocalServerLimits.headerBytes ? .tooLarge : .needMore
        }
        guard terminator.lowerBound <= LocalServerLimits.headerBytes else { return .tooLarge }
        guard let head = HTTPRequest.parseHead(data) else { return .badRequest }

        let requestWithoutBody = HTTPRequest(method: head.method, path: head.path,
                                             headers: head.headers, body: Data())
        if LocalServerCORS.isPreflight(requestWithoutBody) {
            return .ready(requestWithoutBody)
        }
        if !LocalServerAuth.isAuthorized(requestWithoutBody, token: token) {
            return .ready(requestWithoutBody)
        }

        let bodyLimit = LocalServerLimits.bodyBytes(for: head.path)
        guard head.contentLength <= bodyLimit else { return .tooLarge }

        let totalBytes = head.headerByteCount + LocalServerLimits.headerTerminator.count + head.contentLength
        if data.count < totalBytes {
            return data.count > LocalServerLimits.headerBytes + bodyLimit ? .tooLarge : .needMore
        }
        guard let request = HTTPRequest.parse(data, maxBodyBytes: bodyLimit) else { return .badRequest }
        return .ready(request)
    }

    private func respond(to request: HTTPRequest, on connection: ServerConnection) async {
        if LocalServerCORS.isPreflight(request) {
            sendAndClose(.preflight(), on: connection)
            return
        }

        // `/pair` is UNauthenticated by necessity (the extension has no token yet). It is handled BEFORE the
        // token gate and self-gates on the pairing window + a chrome-extension Origin (see handlePair).
        if let route = LocalServerRoute(path: request.path), route == .pair {
            guard route.allows(method: request.method) else {
                sendAndClose(.methodNotAllowed(allow: route.allowedMethods), on: connection)
                return
            }
            await handlePair(request, on: connection)
            return
        }

        guard LocalServerAuth.isAuthorized(request, token: token) else {
            sendAndClose(.unauthorized(), on: connection)
            return
        }

        guard let route = LocalServerRoute(path: request.path) else {
            sendAndClose(.notFound(), on: connection)
            return
        }
        guard route.allows(method: request.method) else {
            sendAndClose(.methodNotAllowed(allow: route.allowedMethods), on: connection)
            return
        }

        switch route {
        case .health:
            sendAndClose(.json(status: 200, reason: "OK", object: ["ok": true]), on: connection)

        case .live:
            await handleLive(request, on: connection)

        case .ask:
            await handleAsk(request, on: connection)

        case .importTranscript:
            await handleImport(request, on: connection)

        case .micState:
            await handleMicState(request, on: connection)

        case .recordStart:
            let started = await onRecordStart()
            sendAndClose(.json(status: 200, reason: "OK", object: ["ok": started, "recording": started]), on: connection)

        case .recordStop:
            await onRecordStop()
            sendAndClose(.json(status: 200, reason: "OK", object: ["ok": true]), on: connection)

        case .recordStatus:
            let s = await recordStatus()
            sendAndClose(.json(status: 200, reason: "OK",
                               object: ["ok": true, "recording": s.recording,
                                        "processing": s.processing, "elapsed": s.elapsed]), on: connection)

        case .pair:
            // Unreachable — handled before the auth gate above; here only for switch exhaustiveness.
            sendAndClose(.notFound(), on: connection)
        }
    }

    /// Hand the pairing token to the extension without any copy-paste. UNauthenticated, so it is gated by:
    /// (1) a short user-initiated window (opened from Settings); (2) a `chrome-extension://` Origin — a real
    /// web page always sends its true https origin and is refused; (3) single-use (the window closes on
    /// success). The token only grants access to this loopback meeting API, never the vault or the DB.
    private func handlePair(_ request: HTTPRequest, on connection: ServerConnection) async {
        // Check the window AND consume it in ONE critical section, so two concurrent `/pair` requests can't
        // both observe it open before either clears it — genuinely single-use even under a race (audit HIGH).
        let origin = request.headers["origin"]
        let allowed = lock.withLock { () -> Bool in
            let windowOpen = (pairingDeadline.map { $0 > Date() }) ?? false
            guard LocalServerAuth.pairAllowed(origin: origin, windowOpen: windowOpen) else { return false }
            pairingDeadline = nil   // consume atomically → the losing racer sees it closed
            return true
        }
        guard allowed else {
            sendAndClose(.json(status: 403, reason: "Forbidden", object: ["ok": false]), on: connection)
            return
        }
        let boundPort = Int(port ?? preferredPort)
        sendAndClose(.json(status: 200, reason: "OK",
                           object: ["ok": true, "token": token, "port": boundPort]), on: connection)
        await onPaired()
    }

    private func handleLive(_ request: HTTPRequest, on connection: ServerConnection) async {
        guard let payload = decode(LivePayload.self, from: request) else {
            sendAndClose(.badRequest(), on: connection)
            return
        }
        session.append(speaker: payload.speaker, text: payload.text, final: payload.final ?? true)
        sendAndClose(.json(status: 200, reason: "OK", object: ["ok": true]), on: connection)
    }

    private func handleAsk(_ request: HTTPRequest, on connection: ServerConnection) async {
        guard let payload = decode(AskPayload.self, from: request) else {
            sendAndClose(.badRequest(), on: connection)
            return
        }
        let query = payload.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            sendAndClose(.badRequest(), on: connection)
            return
        }

        let writer = SSEWriter(connection: connection)
        let generation = SSEGeneration()
        do {
            do {
                try await writer.send(Self.sseHeaders())
            } catch {
                generation.cancelForClientDisconnect()
                throw error
            }
            let liveTranscript = session.transcript()
            let task = Task<String, Error> { [ask, writer, generation] in
                try await ask.askLive(query, transcript: liveTranscript, history: []) { delta in
                    do {
                        try await writer.send(Data(SSEFrameFormatter.data(delta).utf8))
                    } catch {
                        generation.cancelForClientDisconnect()
                    }
                }
            }
            generation.setTask(task)
            _ = try await task.value
            if !generation.didClientDisconnect {
                do {
                    try await writer.send(Data(SSEFrameFormatter.done().utf8))
                } catch {
                    generation.cancelForClientDisconnect()
                }
            }
        } catch is CancellationError {
            if !generation.didClientDisconnect {
                Self.log.error("live ask was cancelled before completion.")
            }
        } catch {
            if generation.didClientDisconnect {
                generation.cancel()
            } else {
                Self.log.error("live ask failed: \(error.localizedDescription, privacy: .public)")
                try? await writer.send(Data(SSEFrameFormatter.error(message: "Live answer failed.").utf8))
            }
        }
        generation.cancel()
        await writer.close()
    }

    private func handleImport(_ request: HTTPRequest, on connection: ServerConnection) async {
        guard let payload = decode(ImportPayload.self, from: request) else {
            sendAndClose(.badRequest(), on: connection)
            return
        }
        // A live recording owns the caption buffer. We still import what the extension sent (never silently
        // drop it — data safety wins over avoiding a rare duplicate, which dedup + the Duplicate Review UI
        // handle), but we must NOT reset the buffer while a recording is accumulating into it, or we'd wipe
        // the captions the recording is about to save (audit HIGH). `resetUnlessRecording` is the guard.
        let transcript = session.transcript()
        let importText = Self.importText(title: payload.title, transcript: transcript)
        let ok = await onImport(importText)
        if ok {
            session.resetUnlessRecording()
        }
        sendAndClose(.json(status: 200, reason: "OK", object: ["ok": ok]), on: connection)
    }

    private func handleMicState(_ request: HTTPRequest, on connection: ServerConnection) async {
        guard let payload = decode(MicStatePayload.self, from: request) else {
            sendAndClose(.badRequest(), on: connection)
            return
        }
        await onMeetMuted(payload.muted)
        sendAndClose(.json(status: 200, reason: "OK", object: ["ok": true]), on: connection)
    }

    private func decode<T: Decodable>(_ type: T.Type, from request: HTTPRequest) -> T? {
        try? JSONDecoder().decode(T.self, from: request.body)
    }

    private func sendAndClose(_ response: HTTPResponse, on connection: ServerConnection) {
        connection.clearReadDeadline()
        connection.raw.send(content: response.data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func sseHeaders() -> Data {
        let text = [
            "HTTP/1.1 200 OK",
            "Content-Type: text/event-stream; charset=utf-8",
            "Cache-Control: no-cache",
            "Connection: close",
            "Access-Control-Allow-Origin: *",
            "",
            "",
        ].joined(separator: "\r\n")
        return Data(text.utf8)
    }

    private static func importText(title: String?, transcript: String) -> String {
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !cleanTitle.isEmpty else { return transcript }
        return "\(cleanTitle)\n\n\(transcript)"
    }

    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        switch endpoint {
        case .hostPort(let host, _):
            switch host {
            case .ipv4(let address):
                return String(describing: address) == "127.0.0.1"
            case .ipv6(let address):
                return String(describing: address) == "::1"
            case .name(let name, _):
                let lower = name.lowercased()
                return lower == "localhost" || lower == "127.0.0.1" || lower == "::1"
            @unknown default:
                return false
            }
        default:
            return false
        }
    }
}

private enum ReadDecision: Sendable {
    case needMore
    case ready(HTTPRequest)
    case tooLarge
    case badRequest
}

private enum LocalServerError: LocalizedError {
    case invalidPort
    case noPortAvailable
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidPort:
            return "Invalid local server port."
        case .noPortAvailable:
            return "No local server port was available."
        case .cancelled:
            return "Local server start was cancelled."
        }
    }
}

private struct LivePayload: Decodable {
    let speaker: String
    let text: String
    let final: Bool?
}

private struct AskPayload: Decodable {
    let query: String
}

private struct ImportPayload: Decodable {
    let title: String?
}

private struct MicStatePayload: Decodable {
    let muted: Bool
}

private struct HTTPResponse {
    let status: Int
    let reason: String
    let headers: [(String, String)]
    let body: Data

    var data: Data {
        var lines = ["HTTP/1.1 \(status) \(reason)"]
        for (name, value) in headers {
            lines.append("\(name): \(value)")
        }
        lines.append("Access-Control-Allow-Origin: \(LocalServerCORS.allowOrigin)")
        lines.append("Content-Length: \(body.count)")
        lines.append("Connection: close")
        lines.append("")
        lines.append("")
        return Data(lines.joined(separator: "\r\n").utf8) + body
    }

    static func json(status: Int, reason: String, object: [String: Any]) -> HTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, reason: reason,
                            headers: [("Content-Type", "application/json; charset=utf-8")],
                            body: body)
    }

    static func preflight() -> HTTPResponse {
        HTTPResponse(status: 204, reason: "No Content",
                     headers: [
                        ("Access-Control-Allow-Methods", LocalServerCORS.allowMethods),
                        ("Access-Control-Allow-Headers", LocalServerCORS.allowHeaders),
                        ("Access-Control-Max-Age", LocalServerCORS.maxAge),
                     ],
                     body: Data())
    }

    static func badRequest() -> HTTPResponse {
        json(status: 400, reason: "Bad Request", object: ["ok": false])
    }

    static func unauthorized() -> HTTPResponse {
        HTTPResponse(status: 401, reason: "Unauthorized",
                     headers: [
                        ("Content-Type", "application/json; charset=utf-8"),
                        ("WWW-Authenticate", "Bearer"),
                     ],
                     body: Data("{\"ok\":false}".utf8))
    }

    static func notFound() -> HTTPResponse {
        json(status: 404, reason: "Not Found", object: ["ok": false])
    }

    static func methodNotAllowed(allow: String) -> HTTPResponse {
        HTTPResponse(status: 405, reason: "Method Not Allowed",
                     headers: [
                        ("Content-Type", "application/json; charset=utf-8"),
                        ("Allow", allow),
                     ],
                     body: Data("{\"ok\":false}".utf8))
    }

    static func payloadTooLarge() -> HTTPResponse {
        json(status: 413, reason: "Payload Too Large", object: ["ok": false])
    }
}

private final class ServerConnection: @unchecked Sendable {
    let id: UUID
    let raw: NWConnection
    private let onCleanup: @Sendable (UUID) -> Void
    private let lock = NSLock()
    private var readDeadline: DispatchWorkItem?
    private var closed = false

    init(id: UUID, raw: NWConnection, onCleanup: @escaping @Sendable (UUID) -> Void) {
        self.id = id
        self.raw = raw
        self.onCleanup = onCleanup
    }

    func scheduleReadDeadline(seconds: TimeInterval, queue: DispatchQueue) {
        let item = DispatchWorkItem { [weak self] in
            self?.cancel()
        }
        let shouldSchedule = lock.withLock {
            guard !closed else { return false }
            readDeadline?.cancel()
            readDeadline = item
            return true
        }
        if shouldSchedule {
            queue.asyncAfter(deadline: .now() + seconds, execute: item)
        }
    }

    func clearReadDeadline() {
        let item = lock.withLock {
            let current = readDeadline
            readDeadline = nil
            return current
        }
        item?.cancel()
    }

    func cancel() {
        let result = lock.withLock {
            guard !closed else { return (false, nil as DispatchWorkItem?) }
            closed = true
            let item = readDeadline
            readDeadline = nil
            return (true, item)
        }
        guard result.0 else { return }
        result.1?.cancel()
        onCleanup(id)
        raw.cancel()
    }
}

private final class SSEGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<String, Error>?
    private var clientDisconnected = false

    var didClientDisconnect: Bool {
        lock.withLock { clientDisconnected }
    }

    func setTask(_ task: Task<String, Error>) {
        let shouldCancel = lock.withLock {
            self.task = task
            return clientDisconnected
        }
        if shouldCancel {
            task.cancel()
        }
    }

    func cancelForClientDisconnect() {
        let current = lock.withLock {
            clientDisconnected = true
            return task
        }
        current?.cancel()
    }

    func cancel() {
        let current = lock.withLock { task }
        current?.cancel()
    }
}

private final class ListenerBox: @unchecked Sendable {
    let raw: NWListener

    init(_ raw: NWListener) {
        self.raw = raw
    }
}

private final class StartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, Error>?
    private var fired = false

    func arm(_ continuation: CheckedContinuation<UInt16, Error>) {
        lock.withLock {
            self.continuation = continuation
        }
    }

    func resume(_ result: Result<UInt16, Error>) {
        let continuation: CheckedContinuation<UInt16, Error>? = lock.withLock {
            guard !fired else { return nil }
            fired = true
            let current = self.continuation
            self.continuation = nil
            return current
        }
        continuation?.resume(with: result)
    }
}

private actor SSEWriter {
    private let connection: ServerConnection

    init(connection: ServerConnection) {
        self.connection = connection
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.raw.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func close() {
        connection.cancel()
    }
}
