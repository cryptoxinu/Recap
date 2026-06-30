import Foundation

/// Confinement box so a non-Sendable model object can be the success value of a shared init `Task`.
/// Safe because the adapters lock-guard creation and use the model serially (one recording at a time).
final class Box<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
