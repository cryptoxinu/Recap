import Foundation

/// Perfection plan Task 3.1 (enabler E2, chat slice) — the chat TURN LIFECYCLE as a pure
/// reducer. The freeze/Stop/double-CLI bug class lived in generation-token guards scattered
/// across seven untested `ChatModel` methods; here the token discipline exists in exactly one
/// place, every event carries the generation it belongs to, and stale generations produce zero
/// effects. `ChatModel` stays the thin @MainActor shell that translates effects into Tasks.
public enum ChatReducer {

    public enum Phase: Sendable, Equatable { case idle, awaitingSources, streaming }

    public struct State: Sendable, Equatable {
        public var phase: Phase = .idle
        /// Monotonic token — bumped on every send/stop/regenerate. Events from any other
        /// generation are dead on arrival (the ONE central guard).
        public var generation = 0
        public var lastQuestion: String?
        public var sourcesCount: Int?
        public var streamedText = ""
        public var stoppedEarly = false
        /// The final validated text disagreed with what streamed (citation validation failed) —
        /// the UI shows an honest "couldn't verify sources" marker instead of the spliced text.
        public var unverifiedStreamReplaced = false
        public var failureMessage: String?
        public init() {}
    }

    public enum Event: Sendable, Equatable {
        case send(question: String)
        case sourcesArrived(generation: Int, count: Int)
        case delta(generation: Int, text: String)
        case finished(generation: Int, finalText: String, cited: Bool, provider: String?)
        case failed(generation: Int, message: String)
        case stop
        case regenerate
        /// Orphan EVERYTHING in flight unconditionally — unlike `.stop`, this bumps the
        /// generation even when idle (round-2 HIGH: a slow async load() that captured the old
        /// generation must never pass the guard after newChat/thread-switch).
        case invalidate
    }

    public enum Effect: Sendable, Equatable {
        case startAsk(generation: Int)
        case cancelAsk(generation: Int)
        case persistTurn
    }

    @discardableResult
    public static func reduce(_ s: inout State, _ event: Event) -> [Effect] {
        switch event {
        case .send(let question):
            let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty, s.phase == .idle else { return [] }   // busy → never a second CLI
            s.generation += 1
            s.phase = .awaitingSources
            s.lastQuestion = q
            s.sourcesCount = nil
            s.streamedText = ""
            s.stoppedEarly = false
            s.unverifiedStreamReplaced = false
            s.failureMessage = nil
            return [.startAsk(generation: s.generation)]

        case .sourcesArrived(let gen, let count):
            guard gen == s.generation, s.phase != .idle else { return [] }
            s.sourcesCount = count
            s.phase = .streaming
            return []

        case .delta(let gen, let text):
            guard gen == s.generation, s.phase != .idle else { return [] }
            s.phase = .streaming
            s.streamedText += text
            return []

        case .finished(let gen, let finalText, let cited, _):
            guard gen == s.generation, s.phase != .idle else { return [] }
            if !cited && !s.streamedText.isEmpty && s.streamedText != finalText {
                s.unverifiedStreamReplaced = true   // streamed prose failed validation — replaced honestly
            }
            s.streamedText = finalText
            s.phase = .idle
            return [.persistTurn]

        case .failed(let gen, let message):
            guard gen == s.generation, s.phase != .idle else { return [] }
            s.failureMessage = message
            s.phase = .idle
            return []

        case .stop:
            guard s.phase != .idle else { return [] }
            let cancelled = s.generation
            s.generation += 1                        // orphan every in-flight event
            s.phase = .idle
            s.stoppedEarly = !s.streamedText.isEmpty
            return [.cancelAsk(generation: cancelled)]

        case .invalidate:
            let wasBusy = s.phase != .idle
            let cancelled = s.generation
            s.generation += 1
            s.phase = .idle
            s.stoppedEarly = false
            return wasBusy ? [.cancelAsk(generation: cancelled)] : []

        case .regenerate:
            guard s.phase == .idle, let q = s.lastQuestion, !q.isEmpty else { return [] }
            s.generation += 1
            s.phase = .awaitingSources
            s.sourcesCount = nil
            s.streamedText = ""
            s.stoppedEarly = false
            s.unverifiedStreamReplaced = false
            s.failureMessage = nil
            return [.startAsk(generation: s.generation)]
        }
    }
}
