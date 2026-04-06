import Foundation

/// File overview:
/// Tracks Tabby's own synthetic key events so inserted suggestions do not recursively trigger
/// the input-monitoring pipeline and cause bogus follow-up completions.
///
/// Suppresses Tabby's own synthetic key events so they do not recursively trigger prediction.
/// This is the same basic idea as ignoring your own optimistic updates in a client event stream.
@MainActor
final class InputSuppressionController {
    private var remainingKeyDownSuppressions = 0
    private var suppressionExpiry = Date.distantPast

    /// Arms a short-lived suppression window for the synthetic keydown events Tabby is about to post.
    func registerSyntheticInsertion(expectedKeyDownCount: Int) {
        remainingKeyDownSuppressions = max(expectedKeyDownCount, 0)
        suppressionExpiry = Date().addingTimeInterval(1.0)
    }

    /// Consumes one pending suppression token if the current event still falls inside the expiry window.
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
