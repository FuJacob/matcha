import Foundation

/// File overview:
/// Assigns monotonically increasing generations to focused-input snapshots so asynchronous
/// suggestion work can prove whether a result is still fresh for the current field.
///
/// Assigns generations to focused input snapshots so stale completions can be rejected safely.
@MainActor
final class ContextBuffer {
    private(set) var currentContext: FocusedInputContext?

    private var lastSignature: String?
    private var lastElementIdentifier: String?
    private var nextGeneration: UInt64 = 0

    /// Converts the latest focus snapshot into a stable context and bumps the generation when
    /// either the field identity or its text/selection signature changes.
    func materialize(from snapshot: FocusedInputSnapshot) -> FocusedInputContext {
        let signature = snapshot.contentSignature

        // We bump the generation whenever either the target field changes or the text/selection
        // inside that field changes. That gives later async work a simple freshness check.
        if snapshot.elementIdentifier != lastElementIdentifier || signature != lastSignature {
            nextGeneration &+= 1
        }

        lastElementIdentifier = snapshot.elementIdentifier
        lastSignature = signature

        let context = FocusedInputContext(snapshot: snapshot, generation: nextGeneration)
        currentContext = context
        return context
    }

    /// Resets the generation baseline when the suggestion pipeline is fully disabled.
    func clear() {
        lastSignature = nil
        lastElementIdentifier = nil
        currentContext = nil
        nextGeneration &+= 1
    }
}
