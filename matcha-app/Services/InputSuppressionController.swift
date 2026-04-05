import Foundation

/// Suppresses Matcha's own synthetic key events so they do not recursively trigger prediction.
/// This is the same basic idea as ignoring your own optimistic updates in a client event stream.
@MainActor
final class InputSuppressionController {
    private var remainingKeyDownSuppressions = 0
    private var suppressionExpiry = Date.distantPast

    func registerSyntheticInsertion(expectedKeyDownCount: Int) {
        remainingKeyDownSuppressions = max(expectedKeyDownCount, 0)
        suppressionExpiry = Date().addingTimeInterval(1.0)
    }

    func consumeIfNeeded() -> Bool {
        guard remainingKeyDownSuppressions > 0 else {
            return false
        }

        guard Date() <= suppressionExpiry else {
            remainingKeyDownSuppressions = 0
            return false
        }

        remainingKeyDownSuppressions -= 1
        return true
    }
}
