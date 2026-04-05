import Foundation

/// Assigns generations to focused input snapshots so stale completions can be rejected safely.
@MainActor
final class ContextBuffer {
    private(set) var currentContext: FocusedInputContext?

    private var lastSignature: String?
    private var lastElementIdentifier: String?
    private var nextGeneration: UInt64 = 0

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

    func clear() {
        lastSignature = nil
        lastElementIdentifier = nil
        currentContext = nil
        nextGeneration &+= 1
    }
}
