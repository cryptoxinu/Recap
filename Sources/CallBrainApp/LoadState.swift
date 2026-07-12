import SwiftUI

/// A small four-state load model so views can tell LOADING apart from FAILED apart from EMPTY —
/// instead of the `@State var x = []` + `try?`-swallow pattern where a read failure looks identical
/// to "nothing here" (or, worse, spins a "Loading…" placeholder forever because `nil` means both
/// "not loaded yet" and "failed"). Adopt via `LoadStateView` for the loading/failed chrome; each
/// view decides what `.loaded` renders (including its own empty state).
enum LoadState<Value> {
    case idle
    case loading
    case loaded(Value)
    case failed

    var value: Value? {
        if case .loaded(let v) = self { return v }
        return nil
    }
    var isLoading: Bool {
        switch self { case .idle, .loading: return true; default: return false }
    }
}

extension LoadState where Value: Sendable {
    /// Run a throwing read OFF the main actor and resolve to `.loaded` / `.failed`. The caller sets
    /// `.loading` before awaiting so the UI shows a spinner (not a stale/empty frame) during the read.
    /// The detached task returns the raw `Value` (Sendable); the state is built back on the caller's actor.
    static func load(_ work: @Sendable @escaping () throws -> Value) async -> LoadState<Value> {
        do {
            let value = try await Task.detached(priority: .userInitiated) { try work() }.value
            return .loaded(value)
        } catch {
            return .failed
        }
    }
}

/// Renders the loading + failed chrome for a `LoadState`; delegates `.loaded` to the caller. Keeps
/// every surface's spinner + retry affordance consistent and prevents the spin-forever failure mode.
struct LoadStateView<Value, Content: View>: View {
    let state: LoadState<Value>
    var loadingLabel: String = "Loading…"
    var failedLabel: String = "Couldn't load that."
    /// `true` fills the pane and centers the chrome (a whole column); `false` renders inline
    /// (a small block inside a scrolling layout, e.g. a detail card region).
    var fill: Bool = true
    let retry: () -> Void
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        switch state {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(loadingLabel).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil)
            .padding(.vertical, fill ? 0 : 16)
            .transition(.opacity)
        case .failed:
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 22)).foregroundStyle(Theme.warning)
                Text(failedLabel).font(.callout).foregroundStyle(.secondary)
                Button("Retry", action: retry).buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil)
            .padding(.vertical, fill ? 0 : 16)
            .transition(.opacity)
        case .loaded(let value):
            content(value)
        }
    }
}
